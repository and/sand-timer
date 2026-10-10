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
    /// The size chosen last time, or Medium the first time.
    static func savedSizeIndex(_ defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.object(forKey: "size") as? Int ?? mediumSizeIndex
        return sizes.indices.contains(saved) ? saved : mediumSizeIndex
    }
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
    private(set) var soundOn = UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true
    /// How loud the falling sand is: 0 unless it's the sound chosen for while the sand runs, 1 its usual level.
    var grainVolume: Double { FocusNoise.shared.sandLoudness }
    private(set) var minuteChimesOn = UserDefaults.standard.bool(forKey: "minuteChimes")
    /// The project that was on when the app last closed, if it still exists and hasn't been removed.
    static func startingProject(_ defaults: UserDefaults = .standard) -> String? {
        guard let id = defaults.string(forKey: ProjectList.activeKey) else { return nil }
        return ProjectList.load(from: defaults).project(id).flatMap { $0.archived ? nil : $0.id }
    }

    /// Sand-time elapsed at the last tick while running, to hear each whole minute go by.
    private var lastElapsed: TimeInterval?
    /// How many minute chimes have played; tests listen here.
    private(set) var minuteChimesPlayed = 0
    /// "Float Anywhere": the timer stays wherever it's let go instead of falling to the bottom of the screen.
    private(set) var floats = UserDefaults.standard.bool(forKey: "float")
    private var flip: (start: Date, from: SandClock)?
    /// Tipping onto its side to pause, or standing back up. `groundY` is the screen y the timer pivots on.
    private var tip: (from: Double, to: Double, start: Date, pivot: CGPoint, side: Double, then: () -> Void)?
    /// Leaning on a base edge: while the top cap is pushed by hand, and while it rocks back upright afterwards.
    private struct Lean {
        var angle: Double
        let side: Double
        let pivot: CGPoint
        /// Being lifted back up from lying on its side, rather than tilted from standing.
        var lifting = false
    }
    /// While lifting a toppled timer by its top cap: where the hand started, as an angle around the pivot, and the lean then.
    private var liftGrab: (handAngle: Double, startAngle: Double)?
    private var lean: Lean?
    /// Screen x where the top cap was grabbed, while the hand holds it.
    private var topGrab: (hand: CGPoint, upright: CGPoint)?
    private var rocking: Rocking?
    /// How each heap has slumped from being tilted (per-column height changes), kept until the sand is next leveled.
    private var topSlump = [Double](repeating: 0, count: SandPhysics.slumpColumns)
    private var bottomSlump = [Double](repeating: 0, count: SandPhysics.slumpColumns)
    /// Screen position of the middle of the top cap, standing or lying down. For grabbing it (and for tests).
    var topCapScreenPoint: CGPoint? {
        guard let window else { return nil }
        let scale = Self.sizes[sizeIndex].scale
        if lyingAngle == 0 { return CGPoint(x: window.frame.midX, y: window.frame.midY + 177 * scale) }
        guard let pivot = lyingPivot else { return nil }
        let offset = SandPhysics.topCapFromPivot(angle: lyingAngle, side: lyingAngle < 0 ? -1 : 1)
        return CGPoint(x: pivot.x + CGFloat(offset.x) * scale, y: pivot.y + CGFloat(offset.y) * scale)
    }

    /// Screen position of the corner a toppled timer lies on (what it swings about when lifted back up).
    var lyingPivot: CGPoint? {
        guard let window, lyingAngle != 0, lean == nil else { return nil }
        let offset = SandPhysics.centerFromPivot(angle: lyingAngle, side: lyingAngle < 0 ? -1 : 1)
        let scale = Self.sizes[sizeIndex].scale
        return CGPoint(x: window.frame.midX - CGFloat(offset.x) * scale, y: window.frame.midY - CGFloat(offset.y) * scale)
    }

    /// How far the timer currently leans from being tilted by hand (radians).
    var handTilt: Double { lean?.angle ?? 0 }
    /// 0 standing up; a quarter turn (positive = fell to the right) while lying on its side, paused.
    private var lyingAngle = 0.0
    /// When the display at the new base switches on after a flip lands.
    private var displayOnAt: Date?
    private static let displayFade = 0.3
    /// How far the hand moves on the top cap before its direction decides between tilting and picking up, in points.
    private static let gestureThreshold: CGFloat = 6
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
    /// Where the pointer is on screen. Tests stand in for the hand here.
    var handLocation: () -> CGPoint = { NSEvent.mouseLocation }
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
    /// What the timer has done, day by day; `Statistics…` shows it.
    private var log = SandLog.load()
    /// The linked phones' records, added together, as the last sync left them: counted with this Mac's own in
    /// Statistics and toward the daily target.
    private var linkedLog = SandLog.linked()
    /// The link to phones, once `Link.start` has set it up; tests leave it nil.
    weak var link: LinkEngine?
    /// Every project, and the one the sand is running for now (nil for none). Time is counted against its id.
    private(set) var projects = ProjectList.load()
    private(set) var activeProjectID: String? = HourglassView.startingProject()
    /// Watches the hand while it drags the timer, for a shake that means "next project".
    private var shake = ShakeGesture()
    /// A project just switched to: its name fades in on the top cap.
    private var projectFlash: (name: String, since: Date)?
    private static let projectFlashDuration = 0.35
    /// A session just ended: the sand left on top slides down to join the rest, from where it was.
    private var ending: (from: Double, start: Date)?
    private static let endingDuration = 0.7
    /// Time run that hasn't been written out yet, and the moment the record has been counted up to while it runs.
    private var unsavedSeconds: TimeInterval = 0
    private var countedUpTo: Date?
    /// How much running time to gather before writing the record out again.
    private static let saveRunEvery: TimeInterval = 30
    /// Called when the user asks to hide the timer in the menu bar.
    var onHide: (() -> Void)?
    /// Snapshot only: angles past the slide threshold show a flip in progress; smaller ones bend the stream.
    var previewAngle: Double?
    /// Snapshot only: shows the day's figure on the base as if the pointer rested there.
    var previewGoalFigure = false
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

    /// Stops driving the timer, and with it any sound it was making. The app never needs this — its timer lives as
    /// long as it does — but a test's timer has to stop when the test does, or it goes on silencing the sounds of
    /// whichever timer is still running.
    func stopTicking() {
        timer?.invalidate()
        timer = nil
        Sounds.setPour(active: false, glassiness: 0)
        Sounds.shake?.stop()
        FocusNoise.shared.silence()
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
        // The focus noise plays while the sand runs, and fades away on a pause, an end or the sand running out.
        FocusNoise.shared.setSessionRunning(running)
        FocusShortcuts.shared.setSessionRunning(running)  // Do Not Disturb, when turned on in Settings
        let finished = wasRunning && !running && clock.progress(at: now) >= 1
        if soundOn && finished {
            NSSound(named: "Glass")?.play()
        }
        if finished {
            sessionStartedAt = nil  // that run is over; the next flip starts another
            publishState()  // the sand has run out: anything reading from outside should know
        }
        wasRunning = running
        if running, let finish = clock.finishTime, abs(finish.timeIntervalSince(publishedFinish ?? finish)) > 1 { publishState() }
        recordRun(finished: finished, at: now)
        let elapsed = running ? clock.progress(at: now) * clock.duration : nil
        if let elapsed, let lastElapsed, clock.minuteChimeDue(from: lastElapsed, to: elapsed), minuteChimesOn {
            minuteChimesPlayed += 1
            Sounds.minuteChime?.stop(); Sounds.minuteChime?.play()
        }
        lastElapsed = elapsed

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

        if var motion = rocking, var current = lean {
            motion.step(dt: dt)
            current.angle = motion.angle
            if let speed = motion.impactSpeed {
                // Its base lands flat again: a small clack, and a jolt for the sand.
                agitation.impact(speed: speed * SandPhysics.timerHeightMeters / 2)
                if soundOn { Sounds.playFall(impactSpeed: speed * SandPhysics.timerHeightMeters) }
            }
            if motion.isSettled {
                rocking = nil
                lean = nil
                if current.lifting { standUpFinished(at: now) }
                placeWindow(around: leanCenter(Lean(angle: 0, side: current.side, pivot: current.pivot)), expanded: false)
            } else {
                rocking = motion
                lean = current
            }
        }
        if let current = lean, !current.lifting, abs(current.angle) > 0.003 { slumpHeaps(tilt: current.angle, at: now) }

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

        if let waiting = awaitingStillness, flip == nil, tip == nil {
            awaitingStillness = nil
            waiting()
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
            topSlump = topSlump.map { $0 * (1 - flatten) }
            bottomSlump = bottomSlump.map { $0 * (1 - flatten) }
        }
        // The top keeps draining, which gradually wears away the shape it slumped into.
        if stream != nil { topSlump = topSlump.map { $0 * exp(-dt / 12) } }
        let visible = window?.isVisible == true
        // Sand is heard whenever it runs, hidden in the menu bar or not: the Sound menu says what plays,
        // and putting the timer away shouldn't quietly contradict it. A hidden timer can't be shaken anyway.
        // Shaken sand rattles, louder the more it's stirred up; it fades with the sand as each jolt settles.
        if let rattle = Sounds.shake {
            let level = min(0.5, agitation.level * 0.55) * (soundOn ? 1 : 0)  // a light rattle, not a shaker; an effect, like a fall
            if level > 0.01 {
                rattle.volume = Float(min(1, level))
                if !rattle.isPlaying { rattle.play() }
            } else if rattle.isPlaying {
                rattle.stop()
            }
        }
        let pouring = grainVolume > 0 && stream.map { $0.front > 150 && $0.tail < 150 } == true
        Sounds.setPour(active: pouring, glassiness: pouring ? SandPhysics.pourGlassiness(progress: clock.progress(at: now)) : 0,
                       volume: grainVolume)

        let moving = flip != nil || tip != nil || lean != nil || !streamLean.isSettled || !agitation.isSettled
        let inMotion = moving || dragged || drop != nil || smoothedVelocity != .zero
        if tip == nil && lean == nil { setExpanded(flip != nil || lyingAngle != 0) }
        let displaySwitchingOn = displayOnAt.map { now.timeIntervalSince($0) < SandPhysics.releaseDelay + Self.displayFade } ?? false
        let flashing = projectFlash.map { now.timeIntervalSince($0.since) < Self.projectFlashDuration } ?? false
        if !flashing, projectFlash != nil { projectFlash = nil; needsDisplay = true }
        let emphasisChanging = timerHover.map { now.timeIntervalSince($0.since) < Self.goalHoverFade } ?? false
        if let timerHover, !timerHover.over, !emphasisChanging { self.timerHover = nil }
        let endingNow = ending.map { now.timeIntervalSince($0.start) < Self.endingDuration } ?? false
        if !endingNow, ending != nil { ending = nil; needsDisplay = true }
        let settling = displaySwitchingOn || goalHoverChanging(at: now) || flashing || emphasisChanging || endingNow
        if let goalHover, !goalHover.over, !goalHoverChanging(at: now) { self.goalHover = nil }
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
        if let ending {
            let t = min(1, now.timeIntervalSince(ending.start) / Self.endingDuration)
            frame.progress = ending.from + (1 - ending.from) * t * t * (3 - 2 * t)
        }
        frame.topSettledProgress = topSettledProgress
        frame.bottomSettledProgress = bottomSettledProgress
        frame.topSlump = topSlump
        frame.bottomSlump = bottomSlump
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
            angle = lean?.angle ?? tipAngle(at: now)
            // Tipping over shakes the heaps flat before the sand slides along the wall.
            frame.shapeAmount = max(0, 1 - abs(angle) / SandPhysics.slideThreshold)
            frame.turning = SandPhysics.lyingSand(angle: angle, progress: frame.progress)
            frame.agitation = previewAgitation ?? agitation.level
        } else if let previewAngle, previewAngle > SandPhysics.slideThreshold {
            angle = previewAngle
            frame.turning = SandPhysics.turningSand(angle: angle, progress: frame.progress)
            frame.agitation = previewAgitation ?? 0
        } else {
            // Leaning by hand, the glass tilts but the stream still falls straight down.
            if let lean { angle = lean.angle }
            frame.streamTilt = (previewAngle ?? streamLean.angle) + angle
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
        } else if let lean, let window {
            let center = leanCenter(lean)
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
        renderer.drawShadow(groundOffset: CGFloat(groundOffset), lying: CGFloat(abs(sin(angle))), strength: CGFloat(strength),
                            sand: theme.sand)
        ctx.restoreGState()

        ctx.saveGState()
        placeTimer(rotated: true)
        // The base display switches off as the timer is tipped to flip it, and the one that ends up at the bottom
        // switches on as the sand starts falling again.
        func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
        var display = BaseDisplay(text: clock.remainingLabel(progress: frame.progress), goal: dailyGoalFraction,
                              goalTicks: SandLog.goalTicks(target: TimeInterval(dailyTargetMinutes * 60)))
        display.plateText = dailyGoalLabel
        display.plateTextOpacity = previewGoalFigure ? 1 : (flip == nil ? goalHoverOpacity(at: now) : 0)
        // The project that's on, on the top cap's lower ring; a new one fades in as it is switched to.
        display.project = projects.project(activeProjectID)?.name
        display.projectEmphasis = projectEmphasis(at: now)
        if let flash = projectFlash { display.projectOpacity = ease(now.timeIntervalSince(flash.since) / Self.projectFlashDuration) }
        if let flip {
            display.brightness = 1 - ease(now.timeIntervalSince(flip.start) / Self.displayFade)
            display.rotation = -angle
        } else if let displayOnAt {
            display.brightness = ease((now.timeIntervalSince(displayOnAt) - SandPhysics.releaseDelay) / Self.displayFade)
        }
        renderer.neckScale = CGFloat(SandPhysics.neckScale(minutes: Double(minutes)))
        renderer.draw(frame, time: CACurrentMediaTime(), theme: theme, display: display)
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        guard let window, flip == nil, tip == nil else { return }
        // Pressing on the top cap of a standing timer: push sideways to tilt it, like a finger on a real one,
        // or pull up to pick it up.
        if canTiltByHand, isOnTopCap(convert(event.locationInWindow, from: nil)) {
            topGrab = (handLocation(), CGPoint(x: window.frame.midX, y: window.frame.midY))
            NSCursor.closedHand.set()
            return
        }
        // Pressing the top cap of a toppled timer: lift it back up about the corner it lies on.
        let hand = window.convertPoint(toScreen: event.locationInWindow)
        if canLiftByHand, isOnLyingTopCap(hand), let pivot = lyingPivot {
            let side: Double = lyingAngle < 0 ? -1 : 1
            let current = Lean(angle: lyingAngle, side: side, pivot: pivot, lifting: true)
            lean = current
            liftGrab = (atan2(Double(hand.y - pivot.y), Double(hand.x - pivot.x)), lyingAngle)
            holdWindowStill(from: leanCenter(current), to: leanCenter(Lean(angle: 0, side: side, pivot: pivot)))
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }
        drop = nil  // caught mid-fall
        drag = (handLocation(), CGPoint(x: window.frame.midX, y: window.frame.midY), screenBox)
        dragged = false
        lastDragSample = nil
        shake.reset()
    }

    override func mouseDragged(with event: NSEvent) {
        if let grab = liftGrab, var current = lean, let window {
            let hand = window.convertPoint(toScreen: event.locationInWindow)
            let sweep = atan2(Double(hand.y - current.pivot.y), Double(hand.x - current.pivot.x)) - grab.handAngle
            current.angle = SandPhysics.leanAngle(startingAt: grab.startAngle, handSweep: atan2(sin(sweep), cos(sweep)), side: current.side)
            lean = current
            needsDisplay = true
            return
        }
        if let grab = topGrab {
            let hand = handLocation()
            let push = hand.x - grab.hand.x
            let side: Double = push < 0 ? -1 : 1
            if lean == nil {
                // The hand's first few points of movement decide what it does, so a shaky sideways push stays a tilt.
                let rise = hand.y - grab.hand.y
                guard hypot(push, rise) > Self.gestureThreshold else { return }
                if rise > abs(push) {
                    // Pulled up: picked up by the top, carried like any drag.
                    topGrab = nil
                    drop = nil
                    drag = (grab.hand, grab.upright, screenBox)
                    dragged = false
                    lastDragSample = nil
                    return mouseDragged(with: event)
                }
                // Pushed down onto a timer standing on the ground: nothing to do.
                guard rise > -abs(push) else { topGrab = nil; return }
                holdWindowStillForLeaning(uprightAt: grab.upright)
            }
            // Swung back past upright to the other side: it now leans on the other corner.
            if lean?.side != side { lean = Lean(angle: 0, side: side, pivot: pivot(side: side, uprightAt: grab.upright)) }
            guard var current = lean else { return }
            let angle = SandPhysics.tiltAngle(forTopShift: Double(push / Self.sizes[sizeIndex].scale))
            current.angle = (angle < 0) == (current.side < 0) ? angle : 0
            lean = current
            // Past its tipping point it goes over on its own.
            if abs(current.angle) >= SandPhysics.tippingAngle { topple(from: current) }
            needsDisplay = true
            return
        }
        guard drag != nil else { return }
        let mouse = handLocation()
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
        let metersPerPoint = SandPhysics.timerHeightMeters / Double(400 * Self.sizes[sizeIndex].scale)
        if shake.feed(velocity: Double(dragVelocity.dx) * metersPerPoint, at: event.timestamp) { shakeToNextProject() }
    }

    override func mouseUp(with event: NSEvent) {
        if let grab = liftGrab, let current = lean {
            liftGrab = nil
            NSCursor.openHand.set()
            if abs(current.angle - grab.startAngle) < 0.01 {
                // Pressed without lifting: put things back and treat it as a click.
                lean = nil
                placeWindow(around: leanCenter(current), expanded: true)
                if event.clickCount == 1 { handleClick() }
            } else if abs(current.angle) <= SandPhysics.tippingAngle {
                rocking = Rocking(angle: current.angle)  // past its balance point: it settles upright
            } else {
                // Not lifted far enough: it falls back onto its side.
                lean = nil
                tip = (from: current.angle, to: current.side * .pi / 2, start: Date(), pivot: current.pivot, side: current.side, then: {})
            }
            return
        }
        if topGrab != nil {
            topGrab = nil
            NSCursor.openHand.set()
            // Let go while leaning: it rocks back upright. Pressed without pushing: an ordinary click.
            if let current = lean { rocking = Rocking(angle: current.angle) } else if event.clickCount == 1 { handleClick() }
            return
        }
        defer { drag = nil; dragged = false }
        guard drag != nil else { return }
        if dragged {
            letGo()
        } else if event.clickCount == 1 {
            handleClick()
        }
    }

    /// Click to start, pause and resume like any timer. A stray click on a running timer only pauses it, which the next
    /// click undoes; flipping mid-run is left to the menu.
    private func handleClick() {
        let now = Date()
        if lyingAngle != 0 && !clock.isPaused(at: now) {
            tipOver(to: 0) {}  // knocked over when it wasn't running: just stand it back up
        } else if clock.isRunning(at: now) {
            pauseClicked()
        } else if clock.isPaused(at: now) {
            resumeClicked()
        } else {
            flipTimer()
        }
    }

    // MARK: Tilting by hand

    private var canLiftByHand: Bool {
        !floats && lyingAngle != 0 && flip == nil && tip == nil && drop == nil && lean == nil
    }

    /// Whether a screen point is on the top cap of the timer lying on its side.
    private func isOnLyingTopCap(_ point: CGPoint) -> Bool {
        guard let pivot = lyingPivot else { return false }
        let scale = Double(Self.sizes[sizeIndex].scale)
        let side: Double = lyingAngle < 0 ? -1 : 1
        // Turn the point back into the standing timer's frame, relative to the pivot corner.
        let rx = Double(point.x - pivot.x) / scale, ry = Double(point.y - pivot.y) / scale
        let x = rx * cos(lyingAngle) - ry * sin(lyingAngle), y = rx * sin(lyingAngle) + ry * cos(lyingAngle)
        let capMiddle = -SandPhysics.outlineHalfWidth * side
        return abs(x - capMiddle) <= SandPhysics.outlineHalfWidth && y >= 350 && y <= 402
    }

    /// Lifted back up past its balance point and settled: it's standing again, so the sand levels and the timer resumes.
    private func standUpFinished(at now: Date) {
        lyingAngle = 0
        settleSand(at: now)
        if clock.isPaused(at: now) {
            clock.resume(at: now)
            releasedAt = now.addingTimeInterval(SandPhysics.releaseDelay)
            publishState()  // standing again is a resume, which a linked phone follows
        }
    }

    private var canTiltByHand: Bool {
        !floats && lyingAngle == 0 && flip == nil && tip == nil && drop == nil && lean == nil
    }

    /// Whether a point in this view is on the top cap of the standing timer.
    private func isOnTopCap(_ point: CGPoint) -> Bool {
        let scale = Self.sizes[sizeIndex].scale
        return abs(point.x - bounds.midX) <= CGFloat(SandPhysics.outlineHalfWidth) * scale
            && point.y >= bounds.midY - 200 * scale && point.y <= bounds.midY - 154 * scale
    }

    private func leanCenter(_ lean: Lean) -> CGPoint {
        let offset = SandPhysics.centerFromPivot(angle: lean.angle, side: lean.side)
        let scale = Self.sizes[sizeIndex].scale
        return CGPoint(x: lean.pivot.x + CGFloat(offset.x) * scale, y: lean.pivot.y + CGFloat(offset.y) * scale)
    }

    /// The bottom corner on `side` of a timer standing with its center at `upright`.
    private func pivot(side: Double, uprightAt upright: CGPoint) -> CGPoint {
        let offset = SandPhysics.centerFromPivot(angle: 0, side: side)
        let scale = Self.sizes[sizeIndex].scale
        return CGPoint(x: upright.x - CGFloat(offset.x) * scale, y: upright.y - CGFloat(offset.y) * scale)
    }

    /// Holds the window still over everything from standing to toppled either way, so the timer can be leaned to one
    /// side, swung back, and leaned to the other without the window moving.
    private func holdWindowStillForLeaning(uprightAt upright: CGPoint) {
        let scale = Self.sizes[sizeIndex].scale
        let fallen = [-1.0, 1.0].map { side -> CGPoint in
            let corner = pivot(side: side, uprightAt: upright)
            let offset = SandPhysics.centerFromPivot(angle: side * .pi / 2, side: side)
            return keptCenter(CGPoint(x: corner.x + CGFloat(offset.x) * scale, y: corner.y + CGFloat(offset.y) * scale), angle: side * .pi / 2)
        }
        holdWindowStill(from: fallen[0], to: fallen[1], alsoCovering: upright)
    }

    /// Past the tipping point: it topples onto its side from where it leans, and pauses like being knocked over.
    private func topple(from current: Lean) {
        let now = Date()
        if clock.isRunning(at: now) {
            clock.pause(at: now)
            publishState()  // knocked over is a pause, which a linked phone follows
        }
        lean = nil
        rocking = nil
        topGrab = nil
        tip = (from: current.angle, to: current.side * .pi / 2, start: now, pivot: current.pivot, side: current.side, then: {})
        needsDisplay = true
    }

    /// Lets each heap slump where tilting has made it steeper than sand can hold, remembering the new shape.
    private func slumpHeaps(tilt: Double, at now: Date) {
        let columns = SandPhysics.slumpColumnOffsets
        let spacing = 2 * SandPhysics.slumpHalfWidth / Double(SandPhysics.slumpColumns - 1)
        let progress = clock.progress(at: now)
        let landed = SandPhysics.landedProgress(progress: progress, settledProgress: bottomSettledProgress,
                                                duration: clock.duration, falling: streamExtent(at: now) != nil)
        if landed > 0 {
            let pile = SandPhysics.bottomPile(progress: landed, settledProgress: bottomSettledProgress)
            let base = columns.map { pile.naturalHeight(atOffset: $0, rough: false) }
            let relaxed = SandPhysics.relaxSlopes(zip(base, bottomSlump).map { $0 + $1 }, spacing: spacing, tilt: tilt, iterations: 3)
            bottomSlump = zip(relaxed, base).map { $0 - $1 }
        }
        if progress < 1 {
            let crater = SandPhysics.topCrater(progress: progress, settledProgress: topSettledProgress)
            let base = columns.map { crater.naturalHeight(atOffset: $0, rough: false) }
            let relaxed = SandPhysics.relaxSlopes(zip(base, topSlump).map { $0 + $1 }, spacing: spacing, tilt: tilt, iterations: 3)
            topSlump = zip(relaxed, base).map { $0 - $1 }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) {
        updateCursor(event)
        updateGoalHover(at: convert(event.locationInWindow, from: nil))
        updateTimerHover(true)
    }
    override func mouseEntered(with event: NSEvent) { updateTimerHover(true) }
    override func mouseExited(with event: NSEvent) {
        updateGoalHover(at: nil)
        updateTimerHover(false)
    }

    /// An open hand over the top cap shows it can be pushed to tilt the timer.
    private func updateCursor(_ event: NSEvent) {
        guard topGrab == nil, liftGrab == nil, let window else { return }
        let overTopCap = (canTiltByHand && isOnTopCap(convert(event.locationInWindow, from: nil)))
            || (canLiftByHand && isOnLyingTopCap(window.convertPoint(toScreen: event.locationInWindow)))
        (overTopCap ? NSCursor.openHand : NSCursor.arrow).set()
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
        sessionStartedAt = now
        publishState()
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
        holdWindowStill(from: start, to: tipCenter(newTip, angle: angle))
        if angle == 0, soundOn, let sound = Sounds.standUp(standUpDuration: Self.standUpDuration) {
            sound.stop()
            sound.play()
        }
        needsDisplay = true
    }

    /// One still window big enough for the timer at any angle anywhere between two centers, so a movement between them
    /// is drawn inside it without the window moving.
    private func holdWindowStill(from start: CGPoint, to end: CGPoint, alsoCovering extra: CGPoint? = nil) {
        guard let window else { return }
        let content = Self.contentSize(sizeIndex: sizeIndex)
        let reach = ceil(hypot(content.width, content.height) / 2) + 2
        let points = [start, end] + (extra.map { [$0] } ?? [])
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        expansion = nil
        window.setFrame(NSRect(x: floor(minX - reach), y: floor(minY - reach),
                               width: ceil(maxX - minX + 2 * reach), height: ceil(maxY - minY + 2 * reach)),
                        display: false)
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

    func makeMenu() -> NSMenu {
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
        if clock.isRunning(at: now) || clock.isPaused(at: now) { menu.addItem(item("End Session", #selector(endClicked))) }
        menu.addItem(item("Hide to Menu Bar", #selector(hideClicked)))  // something to do with the timer, not a setting
        menu.addItem(.separator())

        // Duration is chosen often enough to stay to hand; how the timer looks is set once and then left alone.
        let durations = Self.durations.map { ($0 == Self.pomodoroMinutes ? "\($0) min 🍅" : "\($0) min", $0, $0 == minutes) }
        menu.addItem(submenu("Duration", durations, #selector(durationPicked)))
        menu.addItem(projectMenuItem())
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let looks = NSMenu()
        looks.autoenablesItems = false
        looks.addItem(submenu("Color", Theme.colors.enumerated().map { ($1.name, $0, $0 == themeIndex) }, #selector(themePicked)))
        looks.addItem(submenu("Base", Theme.Base.allCases.map { ($0.name, $0.rawValue, $0 == base) }, #selector(basePicked)))
        looks.addItem(submenu("Size", Self.sizes.enumerated().map { ($1.name, $0, $0 == sizeIndex) }, #selector(sizePicked)))
        appearance.submenu = looks
        menu.addItem(appearance)
        menu.addItem(.separator())

        soundMenuItems().forEach { menu.addItem($0) }
        menu.addItem(.separator())

        menu.addItem(item("Statistics…", #selector(statsClicked)))
        menu.addItem(item("Settings…", #selector(settingsClicked)))
        menu.addItem(item("Getting Started…", #selector(welcomeClicked)))
        menu.addItem(item("Support Sand Timer…", #selector(supportClicked)))
        menu.addItem(.separator())

        if let update = UpdateChecker.shared.available {
            menu.addItem(item("Update to \(Updates.label(update.version))…", #selector(updateClicked)))
        }
        if let version = Updates.currentVersion {
            let running = NSMenuItem(title: "Sand Timer \(Updates.label(version))", action: nil, keyEquivalent: "")
            running.isEnabled = false
            menu.addItem(running)
        }
        // Quit keeps a section to itself: macOS puts an icon on it, and a section holding an icon indents every
        // item in it, which would push the update lines out of line with the rest of the menu.
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Sand Timer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    /// The sound settings, which the menu bar's menu offers too: hidden away there the sand itself falls silently,
    /// but the chimes still play, so there has to be a way to change them without the timer on screen.
    func soundMenuItems() -> [NSMenuItem] { [soundMenuItem()] }

    /// Sound: one choice of what plays while the sand runs — silence, the falling sand, or a noise to work to — then
    /// the short sounds of things happening, each on or off, and the volume in Settings.
    func soundMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "While the sand runs", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        for (index, background) in Background.allCases.enumerated() {
            let entry = item(background.title, #selector(backgroundPicked), tag: index)
            entry.state = FocusNoise.shared.background == background ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let effects = item("Flip, Fall & Finish", #selector(soundToggled))
        effects.state = soundOn ? .on : .off
        menu.addItem(effects)
        let chimes = item("Minute Chimes", #selector(minuteChimesToggled))
        chimes.state = minuteChimesOn ? .on : .off
        menu.addItem(chimes)
        menu.addItem(.separator())
        menu.addItem(item("Sound Settings…", #selector(soundSettingsClicked)))
        parent.submenu = menu
        return parent
    }

    @objc func backgroundPicked(_ sender: NSMenuItem) {
        guard let background = Background.allCases[safe: sender.tag] else { return }
        FocusNoise.shared.choose(background)
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
        topSlump = topSlump.map { _ in 0 }
        bottomSlump = bottomSlump.map { _ in 0 }
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
        publishState()
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
            publishState()
            needsDisplay = true
        }
        if lyingAngle != 0 { tipOver(to: 0, then: resume) } else if tip == nil { resume() }
    }

    @objc private func flipClicked() { flipTimer() }

    @objc func restartClicked() {
        let restart = { [weak self] in
            guard let self else { return }
            clock.restart(at: Date())
            releasedAt = Date()
            sessionStartedAt = Date()
            publishState()
            topSettledProgress = 0
            bottomSettledProgress = 0
            topSlump = topSlump.map { _ in 0 }
            bottomSlump = bottomSlump.map { _ in 0 }
            needsDisplay = true
        }
        guard flip == nil, tip == nil else { return }
        if lyingAngle != 0 { tipOver(to: 0, then: restart) } else { restart() }
    }

    /// Ends the session here: done for now. The time run is kept, but it isn't a finished timer — the sand didn't run
    /// out — so nothing chimes and the finished count stays honest. The sand still on top settles to the bottom, a
    /// paused timer is stood back up first, and the timer then waits to be clicked, free to change project.
    @objc func endClicked() {
        let end = { [weak self] in
            guard let self else { return }
            let now = Date()
            guard clock.isRunning(at: now) || clock.isPaused(at: now) else { return }
            recordRun(finished: false, at: now)
            ending = (clock.progress(at: now), now)
            clock = SandClock(duration: clock.duration)  // all the sand below, waiting to be turned over
            countedUpTo = nil
            wasRunning = false  // so the tick doesn't take this for the sand running out
            releasedAt = nil
            sessionStartedAt = nil
            agitation.impact(speed: 0.8)  // a soft settle as the sand comes down
            publishState()
            needsDisplay = true
        }
        guard flip == nil, tip == nil else { return }
        let now = Date()
        guard clock.isRunning(at: now) || clock.isPaused(at: now) else { return }
        if lyingAngle != 0 { tipOver(to: 0, then: end) } else { end() }
    }

    /// Ends the session, as `sandtimer://end` asks: waits for the glass to be still, like the other commands.
    func endSession() { whenStill { [weak self] in self?.endClicked() } }

    @objc private func hideClicked() { onHide?() }

    @objc func floatToggled() {
        floats.toggle()
        UserDefaults.standard.set(floats, forKey: "float")
        letGo()  // floating: stay put; not floating any more: fall to the bottom of the screen
    }
    @objc private func supportClicked() { NSWorkspace.shared.open(Self.supportURL) }

    @objc func updateChecksToggled() { UpdateChecker.shared.setEnabled(!UpdateChecker.shared.isEnabled) }

    /// Opens the page for the newer release. Nothing is downloaded or installed on the user's behalf.
    @objc func updateClicked() { NSWorkspace.shared.open(UpdateChecker.shared.available?.page ?? Updates.releasesPage) }

    // MARK: What the timer is doing, for anything reading from outside

    /// Whether commands from Claude, Shortcuts or a script are accepted at all.
    private(set) var allowsControl = UserDefaults.standard.bool(forKey: TimerState.controlKey)
    /// When this run of the sand began. A pause doesn't end it; the sand running out does.
    private var sessionStartedAt: Date?
    /// A command that arrived while the glass was still turning or falling, to be carried out once it settles.
    private var awaitingStillness: (() -> Void)?

    /// Writes down what the timer is doing now, so the MCP server can answer without asking the app, and tells a
    /// linked phone.
    func publishState() {
        let state = currentState(at: Date())
        UserDefaults.standard.set(state.stored, forKey: TimerState.key)
        publishedFinish = state.runningUntil
        link?.timerChanged()
    }

    /// When the sand was last said to run out. Leaning the glass or shaking it changes how fast the sand falls, so
    /// the tick says so again once that has moved by more than a second.
    private var publishedFinish: Date?

    private func currentState(at now: Date) -> TimerState {
        var state = TimerState(minutes: minutes, updated: now, project: activeProjectID)
        if clock.isRunning(at: now) {
            state.started = sessionStartedAt
            state.runningUntil = clock.finishTime
        } else if clock.isPaused(at: now) {
            state.started = sessionStartedAt
            state.pausedWith = clock.remaining(at: now)
        }
        return state
    }

    /// Seconds of sand left, as of now.
    var secondsLeft: TimeInterval { clock.remaining(at: Date()) }

    /// Picks up a run where the last launch left it: sand that was flowing carries on from where it would have got to,
    /// and a paused timer is laid down again with what it had left. A run that finished while the app was away is
    /// simply over, and gets no chime now. Only the app's own start-up calls this; it is the note `publishState` keeps.
    func restoreSession(from stored: [String: Any]? = UserDefaults.standard.dictionary(forKey: TimerState.key)) {
        let now = Date()
        let state = TimerState.load(stored: stored)
        let left = state.remaining(at: now)
        guard state.minutes == minutes, left > 0, flip == nil, tip == nil, !clock.isRunning(at: now) else { return }
        // Restored as running, whichever it was: a paused one is then paused in the ordinary way, which lays it down.
        clock = SandClock(duration: clock.duration, progress: 1 - min(1, left / clock.duration), runningSince: now)
        sessionStartedAt = state.started ?? now
        releasedAt = .distantPast  // the stream is already falling, not starting to
        if state.isPaused(at: now) { DispatchQueue.main.async { [weak self] in self?.pauseClicked() } }
        publishState()
        needsDisplay = true
    }

    /// Starts a fresh session, optionally of a different length: what `sandtimer://start` asks for.
    func startSession(minutes newMinutes: Int?) {
        whenStill { [weak self] in
            if let newMinutes { self?.setDuration(minutes: newMinutes) }
            self?.restartClicked()
        }
    }

    func pauseSession() { whenStill { [weak self] in self?.pauseClicked() } }
    func resumeSession() { whenStill { [weak self] in self?.resumeClicked() } }

    /// A hand on the timer waits for it to stop rocking before pressing again; a command arriving from elsewhere
    /// has no way of knowing, so it waits here instead of being dropped while the glass is mid-turn or mid-fall.
    private func whenStill(_ command: @escaping () -> Void) {
        if flip == nil, tip == nil {
            command()
        } else {
            awaitingStillness = command
        }
    }

    /// Any length from a minute to an hour, which is wider than the menu offers — "start a seven minute timer" is a
    /// reasonable thing to ask for, even if it isn't worth a line in the menu.
    func setDuration(minutes newMinutes: Int) {
        minutes = min(60, max(1, newMinutes))
        clock.setDuration(TimeInterval(minutes * 60), at: Date())
        UserDefaults.standard.set(minutes, forKey: "minutes")
        publishState()
        needsDisplay = true
    }

    @objc func controlToggled() {
        allowsControl.toggle()
        UserDefaults.standard.set(allowsControl, forKey: TimerState.controlKey)
        publishState()
    }

    // MARK: Statistics

    /// Minutes of running time to aim for each day; 0 is no target. The label beside the timer shows today's progress.
    static let dailyTargetKey = "dailyTargetMinutes"
    private(set) var dailyTargetMinutes = max(0, UserDefaults.standard.integer(forKey: HourglassView.dailyTargetKey))

    /// A day has only so many minutes; anything past that is a typing slip.
    static let longestDailyTarget = 24 * 60

    func setDailyTarget(minutes: Int) {
        dailyTargetMinutes = min(Self.longestDailyTarget, max(0, minutes))
        UserDefaults.standard.set(dailyTargetMinutes, forKey: Self.dailyTargetKey)
        needsDisplay = true
    }

    /// "21:18/60:00": how long the sand has run today against the target, or nil when there is no target.
    var dailyGoalLabel: String? {
        guard dailyTargetMinutes > 0 else { return nil }
        return SandLog.goalLabel(seconds: secondsToday, target: TimeInterval(dailyTargetMinutes * 60))
    }

    /// How much of the target today's sand has run: 1 is all of it, and a day can go past it.
    private var dailyGoalFraction: Double? {
        guard dailyTargetMinutes > 0 else { return nil }
        return secondsToday / TimeInterval(dailyTargetMinutes * 60)
    }

    /// How long the sand has run today, here and on any linked phone.
    private var secondsToday: TimeInterval { log.seconds(on: Date()) + linkedLog.seconds(on: Date()) }

    /// Reads the linked phones' records again, after a sync.
    func reloadLinked() {
        linkedLog = SandLog.linked()
        needsDisplay = true
    }

    /// While the pointer rests on the base plate, the day's figure is printed above the line: "21:18/3:00:00". It fades
    /// in after a moment, so passing over the timer doesn't flash it, and out again as the pointer leaves.
    private var goalHover: (since: Date, over: Bool)?
    private static let goalHoverDelay = 0.25
    private static let goalHoverFade = 0.2

    /// How strongly the hover figure is showing, 0 to 1.
    private func goalHoverOpacity(at now: Date) -> Double {
        guard let goalHover else { return 0 }
        func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
        return goalHover.over
            ? ease((now.timeIntervalSince(goalHover.since) - Self.goalHoverDelay) / Self.goalHoverFade)
            : 1 - ease(now.timeIntervalSince(goalHover.since) / Self.goalHoverFade)
    }

    /// The pointer resting anywhere on the timer: the project's name comes forward, so it can be read, and goes back
    /// to a faint mark when the pointer leaves. Same fade as the hover figure, without the wait.
    private var timerHover: (since: Date, over: Bool)?

    private func projectEmphasis(at now: Date) -> Double {
        guard let timerHover else { return 0 }
        func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
        let t = now.timeIntervalSince(timerHover.since) / Self.goalHoverFade
        return timerHover.over ? ease(t) : 1 - ease(t)
    }

    private func updateTimerHover(_ over: Bool) {
        guard over != (timerHover?.over ?? false) else { return }
        let now = Date()
        let shown = projectEmphasis(at: now)
        // Start the fade from wherever it had got to, so a quick in-and-out doesn't jump.
        timerHover = over ? (now.addingTimeInterval(-shown * Self.goalHoverFade), true)
                          : (now.addingTimeInterval(-(1 - shown) * Self.goalHoverFade), false)
        needsDisplay = true
    }

    /// Whether the project's name is brought forward: tests look here.
    var projectNameEmphasised: Bool { projectEmphasis(at: Date()) > 0.5 }

    /// Stands in for the pointer arriving on the timer or leaving it: for tests.
    func hoverTimer(_ over: Bool) { updateTimerHover(over) }

    /// Whether the hover figure is fading in or out, which needs the timer redrawn even when the sand is still.
    private func goalHoverChanging(at now: Date) -> Bool {
        guard let goalHover else { return false }
        return now.timeIntervalSince(goalHover.since) < (goalHover.over ? Self.goalHoverDelay : 0) + Self.goalHoverFade
    }

    /// The base plate, standing up, in the view's own coordinates: where hovering shows the day's figure.
    func isOnBasePlate(_ point: CGPoint) -> Bool {
        let scale = Self.sizes[sizeIndex].scale
        return abs(point.x - bounds.midX) <= 93 * scale
            && point.y >= bounds.midY + 177 * scale && point.y <= bounds.midY + 200 * scale
    }

    /// Notes the pointer arriving on or leaving the base plate. Only while there is a target and the timer is standing
    /// still — a figure appearing mid-flip would only be in the way.
    private func updateGoalHover(at point: CGPoint?) {
        let still = flip == nil && tip == nil && lean == nil && lyingAngle == 0 && drag == nil && drop == nil
        let over = dailyTargetMinutes > 0 && still && point.map(isOnBasePlate) == true
        let now = Date()
        if over == (goalHover?.over ?? false) { return }
        if over {
            goalHover = (now, true)
        } else if goalHover != nil {
            // Fade out from however far it had got.
            let shown = goalHoverOpacity(at: now)
            goalHover = shown > 0 ? (now.addingTimeInterval(-(1 - shown) * Self.goalHoverFade), false) : nil
        }
        needsDisplay = true
    }

    /// Whether the day's figure is showing over the base: tests look here.
    var showsGoalFigure: Bool { goalHoverOpacity(at: Date()) > 0.5 }

    /// Stands in for the pointer resting on the base plate, or leaving it: for tests.
    func hoverBasePlate(_ over: Bool) {
        let scale = Self.sizes[sizeIndex].scale
        updateGoalHover(at: over ? CGPoint(x: bounds.midX, y: bounds.midY + 190 * scale) : nil)
    }

    var startsAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    @objc func settingsClicked() { SettingsPanel.show(for: self) }
    @objc func soundSettingsClicked() { SettingsPanel.show(for: self, page: 2) }
    @objc func manageProjectsClicked() { SettingsPanel.show(for: self, page: 1) }

    @objc func welcomeClicked() { WelcomePanel.show(for: self) }

    /// What the statistics window draws, read afresh each time it refreshes.
    var statistics: Statistics {
        Statistics(log: log.including(linkedLog), sand: Theme(color: themeIndex, base: base).sand, projects: projects)
    }

    /// The sand's colour and the caps': the project's colour while one is on, the Appearance colour otherwise.
    var theme: Theme {
        if let color = projects.project(activeProjectID).flatMap({ NSColor(hex: $0.color) }) { return Theme(sand: color, base: base) }
        return Theme(color: themeIndex, base: base)
    }

    // MARK: Projects

    /// "One Thing at a Time": the project stays put for the whole of a session — running or paused — and can be changed
    /// only once the sand has run out or before it starts. On unless turned off: hopping between things mid-session is
    /// what the timer is there to calm.
    static let oneThingKey = "oneThingAtATime"
    private(set) var oneThingAtATime = UserDefaults.standard.object(forKey: HourglassView.oneThingKey) as? Bool ?? true

    @objc func oneThingToggled() {
        oneThingAtATime.toggle()
        UserDefaults.standard.set(oneThingAtATime, forKey: Self.oneThingKey)
    }

    /// Whether the project can be changed now: always, unless One Thing at a Time is on and a session is under way.
    var canSwitchProject: Bool {
        let now = Date()
        return !oneThingAtATime || (!clock.isRunning(at: now) && !clock.isPaused(at: now))
    }

    /// Starts counting against another project (nil for none). The time run so far is counted against the one before,
    /// right up to this moment, so a switch mid-run splits the run exactly where it happened. Under One Thing at a
    /// Time a switch mid-session is declined, unless `force`d — as when the project that's on is removed.
    func switchProject(to id: String?, force: Bool = false) {
        guard force || canSwitchProject else { return }
        let now = Date()
        let chosen = projects.project(id).flatMap { $0.archived ? nil : $0.id }
        guard chosen != activeProjectID else { return }
        recordRun(finished: false, at: now)
        activeProjectID = chosen
        if let chosen { UserDefaults.standard.set(chosen, forKey: ProjectList.activeKey) } else { UserDefaults.standard.removeObject(forKey: ProjectList.activeKey) }
        projectFlash = (projects.name(of: chosen ?? ""), now)
        publishState()
        needsDisplay = true
    }

    /// Takes a changed list of projects from Settings. Removing the project that's on switches to none.
    func updateProjects(_ list: ProjectList) {
        takeLinkedProjects(list.stamped(since: projects, at: Date()))
        link?.projectsChanged()
    }

    /// Takes a list of projects as it stands, already stamped: from Settings by way of `updateProjects`, or put
    /// together with a linked phone's.
    func takeLinkedProjects(_ list: ProjectList) {
        projects = list
        list.save()
        if projects.project(activeProjectID)?.archived != false { switchProject(to: nil, force: true) }
        needsDisplay = true
    }

    /// A shake while holding the timer: on to the next project marked for shaking.
    func shakeToNextProject() {
        guard canSwitchProject, let next = projects.nextForShake(after: activeProjectID) else { return }
        switchProject(to: next.id)
    }

    /// The name printed on the top cap: the project that's on, or nothing. Tests look here.
    var shownProjectName: String? { projects.project(activeProjectID)?.name }

    @objc private func projectPicked(_ sender: NSMenuItem) {
        switchProject(to: sender.representedObject as? String)
    }

    /// The Project submenu: every project in use with the active one ticked, No Project, and a way to manage them.
    func projectMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Under One Thing at a Time, mid-session: the projects wait, and ending the session — a choice made on purpose,
        // right here — is the way to another one.
        let open = canSwitchProject
        if !open {
            let note = NSMenuItem(title: "End the session to switch", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            let end = NSMenuItem(title: "End Session", action: #selector(endClicked), keyEquivalent: "")
            end.target = self
            menu.addItem(end)
            menu.addItem(.separator())
        }
        for project in projects.visible {
            let entry = NSMenuItem(title: project.name, action: #selector(projectPicked(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = project.id
            entry.state = project.id == activeProjectID ? .on : .off
            entry.image = NSColor(hex: project.color).map(Self.swatch)
            entry.isEnabled = open
            menu.addItem(entry)
        }
        if !projects.visible.isEmpty { menu.addItem(.separator()) }
        let none = NSMenuItem(title: ProjectList.untitled, action: #selector(projectPicked(_:)), keyEquivalent: "")
        none.target = self
        none.state = activeProjectID == nil ? .on : .off
        none.isEnabled = open
        menu.addItem(none)
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Projects…", action: #selector(manageProjectsClicked), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        parent.submenu = menu
        if let active = projects.project(activeProjectID) { parent.title = "Project: \(active.name)" }
        return parent
    }

    /// A small round swatch of a project's colour, for menus.
    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            NSColor(white: 0, alpha: 0.2).setStroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).stroke()
            return true
        }
    }

    @objc func statsClicked() {
        saveStatistics(at: Date())  // the window shouldn't have to wait for the next batch
        StatsPanel.show { [weak self] in self?.statistics ?? Statistics(log: SandLog(), sand: .systemPurple) }
    }

    /// Counts the time the sand has actually been running since the last tick, and the timers that run all the way
    /// out. Real time, not sand time: a flip moves the sand about without adding to the day.
    private func recordRun(finished: Bool, at now: Date) {
        // A session a linked phone started is counted there; here it only shows.
        let counts = link?.countsHere ?? true
        if counts, let since = countedUpTo {
            // Sand stops at the moment the top empties, however late this tick comes — the Mac may have slept.
            let until = min(now, clock.finishTime ?? now)
            if until > since {
                log.add(seconds: until.timeIntervalSince(since), project: activeProjectID ?? "", on: until)
                unsavedSeconds += until.timeIntervalSince(since)
            }
        }
        countedUpTo = clock.isRunning(at: now) ? now : nil
        if finished && counts { log.add(finished: 1, project: activeProjectID ?? "", on: now) }
        // Written in batches while it runs, and once more as soon as it stops: a crash costing a few seconds of the
        // record matters less than writing on every frame would.
        if finished || unsavedSeconds >= Self.saveRunEvery || (countedUpTo == nil && unsavedSeconds > 0) {
            saveStatistics(at: now)
        }
    }

    /// Writes the record out now: the app is quitting, and the last few seconds of sand shouldn't be lost with it.
    func flushStatistics() { saveStatistics(at: Date()) }

    private func saveStatistics(at now: Date) {
        log.prune(at: now)
        log.save()
        unsavedSeconds = 0
    }

    @objc func loginToggled() {
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

    @objc func soundToggled() {
        soundOn.toggle()
        UserDefaults.standard.set(soundOn, forKey: "soundOn")
    }

    @objc func minuteChimesToggled() {
        minuteChimesOn.toggle()
        UserDefaults.standard.set(minuteChimesOn, forKey: "minuteChimes")
    }

    @objc private func durationPicked(_ sender: NSMenuItem) { setDuration(minutes: sender.tag) }

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
        UserDefaults.standard.set(sizeIndex, forKey: "size")
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

// MARK: A linked phone

extension HourglassView: LinkHost {
    func ownLog() -> SandLog { log }

    func localTimer() -> SharedTimer {
        let state = currentState(at: Date())
        return SharedTimer(minutes: state.minutes, started: state.started, runningUntil: state.runningUntil,
                           pausedWith: state.pausedWith, project: state.project)
    }

    func linkChanged() { reloadLinked() }

    /// Takes on the timer as a linked phone left it: flipped, paused, resumed, ended, or set to another length or
    /// project there. The glass moves as if a hand had done it here, then the sand is put exactly where the phone's is.
    func adopt(_ timer: SharedTimer, counts: Bool) {
        whenStill { [weak self] in self?.adoptNow(timer) }
    }

    private func adoptNow(_ shared: SharedTimer) {
        let now = Date()
        if shared.project != activeProjectID { switchProject(to: shared.project, force: true) }
        let running = clock.isRunning(at: now), paused = clock.isPaused(at: now)
        let left = shared.remaining(at: now)
        func useLength() {
            guard shared.minutes != minutes else { return }
            minutes = min(60, max(1, shared.minutes))
            UserDefaults.standard.set(minutes, forKey: "minutes")
        }
        /// The sand where the phone's is: `left` seconds of it still on top, falling or not.
        func placeSand(flowing: Bool) {
            useLength()
            let duration = TimeInterval(minutes * 60)
            clock = SandClock(duration: duration, progress: 1 - min(1, left / duration), runningSince: flowing ? now : nil)
            sessionStartedAt = shared.started ?? now
        }
        switch shared.phase(at: now) {
        case .running:
            if running {
                guard !shared.sameSession(as: localTimer()) || abs((clock.finishTime ?? now).timeIntervalSince(shared.runningUntil!)) > 1
                else { break }
                placeSand(flowing: true)
                settleSand(at: now)
                releasedAt = now
            } else if paused {
                placeSand(flowing: false)
                resumeClicked()  // stands it up, and the sand runs again
            } else {
                useLength()
                flipTimer()
                placeSand(flowing: true)
            }
        case .paused:
            if running {
                pauseClicked()  // lays it down
                placeSand(flowing: false)
            } else if paused {
                placeSand(flowing: false)
            } else {
                placeSand(flowing: true)  // as when the app reopens on a paused timer: standing, then laid down
                releasedAt = .distantPast
                pauseClicked()
            }
        case .idle:
            if running || paused { endClicked() } else if shared.minutes != minutes { setDuration(minutes: shared.minutes) }
        }
        publishState()
        needsDisplay = true
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
