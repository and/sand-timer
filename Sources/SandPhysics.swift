import Foundation

/// How the sand physically behaves, in the renderer's 200 x 400 unit space
/// (neck at x = 100, y = 200; y grows downward). Pure functions, so it can be tested without AppKit.
enum SandPhysics {
    typealias G = HourglassGeometry
    static let geometry = HourglassGeometry()

    static let centerX = 100.0
    static let neckY = 200.0
    static let earthGravity = 9.81
    /// Real-world height of the timer, used to turn on-screen motion into physical motion.
    static let timerHeightMeters = 0.15
    /// Slope of a sand heap at its angle of repose (about 27°).
    static let reposeSlope = 0.5
    /// Units per second squared: a grain falls the length of a bulb in about a quarter of a second.
    static let gravity = 4800.0
    /// Pause after a flip lands before sand starts through the neck.
    static let releaseDelay = 0.12
    /// How far (radians) the glass must turn during a flip before the sand lets go and slides.
    static let slideThreshold = 0.61
    private static let sliceHeight = 1.0

    /// Reference duration for the neck as drawn at `neckScale` 1.
    static let referenceMinutes = 25.0

    /// How wide the neck must be, relative to the reference timer, for the same sand to run out in `minutes`.
    /// Sand pours through an opening at a rate proportional to its width to the power 2.5 (Beverloo's law), and the
    /// amount is fixed, so width ∝ minutes^-0.4. Capped so the shortest timers still look like an hourglass; real
    /// short timers get the rest of the way with coarser sand. Long timers narrow only half as much (on a log scale),
    /// since real ones use finer sand, which keeps their stream from looking implausibly thin.
    static func neckScale(minutes: Double) -> Double {
        let width = pow(referenceMinutes / max(minutes, 0.01), 0.4)
        return min(2.6, max(0.6, width < 1 ? width.squareRoot() : width))
    }

    /// What the falling stream looks like `fraction` of the way from the neck down to where it lands. Grains leave the
    /// neck packed together and spread apart as they speed up, so the solid core narrows and fades while loose grains
    /// stray further out. Widths are relative to the opening.
    struct StreamSlice {
        let coreWidth: Double
        let coreOpacity: Double
        /// How far loose grains stray from the center line, in opening widths.
        let spread: Double
    }

    static func streamSlice(at fraction: Double) -> StreamSlice {
        let f = min(max(fraction, 0), 1)
        // In a real hourglass the loosening is barely visible: the stream reads as a thin, steady thread.
        return StreamSlice(coreWidth: 1 - 0.1 * f, coreOpacity: 0.95 - 0.1 * f, spread: 0.1 + 0.15 * f)
    }

    /// Distance (drawing units) below the neck over which the sand in the opening converges into the stream.
    static func funnelLength(neckScale: Double) -> Double { 2 + 1.5 * neckScale }

    /// How fast sand pours, relative to normal, when it feels `gravityFactor` times normal gravity. Flow through an
    /// opening goes with the square root of gravity, so it quickens when the timer is lifted sharply, slows when it's
    /// lowered, and stops altogether in free fall.
    static func flowRate(gravityFactor: Double) -> Double { max(0, gravityFactor).squareRoot() }

    /// Below this share of normal gravity no grains leave the neck, so the stream lets go and falls away.
    static let freeFallThreshold = 0.05

    static func fallDistance(after seconds: Double) -> Double {
        seconds <= 0 ? 0 : 0.5 * gravity * seconds * seconds
    }

    // MARK: Resting shapes

    /// Volume of a conical pile whose peak stands `peak` units above the lower cap.
    static func pileVolume(peak: Double, slope: Double = reposeSlope) -> Double {
        integrate(upTo: min(peak, G.halfLength)) { z in
            let radius = min(G.innerRadius(G.halfLength - z), (peak - z) / slope)
            return .pi * radius * radius
        }
    }

    /// Peak height above the lower cap of a pile holding `volume`.
    static func pilePeak(volume: Double, slope: Double = reposeSlope) -> Double {
        guard volume > 0 else { return 0 }
        return bisect(0, G.halfLength + slope * G.bulbRadius) { pileVolume(peak: $0, slope: slope) < volume }
    }

    /// Volume left in the upper bulb when a funnel crater with its tip `tip` units above the neck
    /// has been drawn into sand that was flat at `flatLevel`.
    static func craterVolume(tip: Double, flatLevel: Double, slope: Double = reposeSlope) -> Double {
        integrate(upTo: min(flatLevel, G.halfLength)) { d in
            let wall = G.innerRadius(d)
            let hole = max(0, (d - tip) / slope)
            return hole < wall ? .pi * (wall * wall - hole * hole) : 0
        }
    }

    /// Tip height of the crater once the sand that started flat at `flatLevel` is down to `volume`.
    /// Equals `flatLevel` (no crater) when nothing has drained. The funnel walls are steeper than the sand's slope,
    /// so near the end the tip sinks toward the neck and the last sand drains as a shallow cone.
    static func craterTip(volume: Double, flatLevel: Double, slope: Double = reposeSlope) -> Double {
        let lowest = -slope * (G.bulbRadius + 1)
        if volume >= craterVolume(tip: flatLevel, flatLevel: flatLevel, slope: slope) { return flatLevel }
        if volume <= 0 { return lowest }
        return bisect(lowest, flatLevel) { craterVolume(tip: $0, flatLevel: flatLevel, slope: slope) < volume }
    }

    /// The lower bulb's sand: a flat layer of whatever had already settled there (after a flip, being stood back up, or
    /// a hard shake), with the sand that has fallen since piled on top of it as a cone at the angle of repose.
    struct BottomPile {
        /// Height of the flat layer above the cap.
        let layer: Double
        /// Height of the cone's tip above the layer.
        let peak: Double

        func height(atRadius rho: Double) -> Double { layer + max(0, peak - reposeSlope * rho) }

        /// The surface as it really looks at a horizontal `offset` from the center: a slightly rounded peak, a foot that
        /// curves into the layer instead of meeting it at a corner, and faint unevenness. Nearly the same sand as `height`.
        func naturalHeight(atOffset offset: Double, rough: Bool = true) -> Double {
            let cone = NaturalSurface.roundedCone(peak: peak, slope: reposeSlope, radius: abs(offset), tipRadius: 5)
            let heap = NaturalSurface.smoothMax(0, cone, width: 3)
            return layer + heap + (rough ? 0.7 * NaturalSurface.roughness(at: offset) : 0)
        }

        /// How far out the cone reaches before it meets the layer or the wall.
        var foot: Double { min(G.innerRadius(G.halfLength - layer), peak / reposeSlope) }
    }

    /// Seconds a grain spends between leaving the top and landing at the bottom: the pause before the stream is let go,
    /// then the fall through the lower bulb.
    static var flightTime: Double { releaseDelay + (2 * G.halfLength / gravity).squareRoot() }

    /// How much of the sand has actually landed in the lower bulb. While sand is falling, the last `flightTime` seconds'
    /// worth is still in the air, so the pile lags the top; it never dips below what had already settled.
    static func landedProgress(progress: Double, settledProgress: Double, duration: Double, falling: Bool) -> Double {
        guard falling, duration > 0 else { return progress }
        return min(progress, max(settledProgress, progress - flightTime / duration))
    }

    static func bottomPile(progress: Double, settledProgress: Double) -> BottomPile {
        let settled = min(max(0, settledProgress), progress)
        let layer = settled > 0 ? G.halfLength - geometry.bottomSurfaceDistance(progress: settled) : 0
        return BottomPile(layer: layer, peak: pilePeak(volume: geometry.sandVolume * max(0, progress - settled)))
    }

    /// The upper bulb's sand: flat at the level it had when it last settled, with a funnel crater drawn down into it by
    /// the sand that has drained since.
    struct TopCrater {
        /// Height of the flat surface above the neck when it last settled.
        let level: Double
        /// Height of the crater's tip above the neck.
        let tip: Double

        func height(atRadius rho: Double) -> Double { max(0, min(level, tip + reposeSlope * rho)) }

        /// The surface as it really looks: a crater with a rounded bottom and a rim that curves into the flat sand
        /// around it, with faint unevenness. Nearly the same sand as `height`.
        func naturalHeight(atOffset offset: Double, rough: Bool = true) -> Double {
            let funnel = tip + reposeSlope * ((offset * offset + 16).squareRoot() - 4)
            let surface = NaturalSurface.smoothMin(level, funnel, width: 4)
            return NaturalSurface.smoothMax(0, surface, width: 1.5) + (rough ? 0.5 * NaturalSurface.roughness(at: offset + 17) : 0)
        }

        /// Where the crater meets the flat surface.
        var rim: Double { max(0, min(G.bulbRadius, (level - tip) / reposeSlope)) }
    }

    /// Helpers that turn the ideal heap shapes into how sand actually looks, without meaningfully changing how much there is.
    enum NaturalSurface {
        /// Larger of `a` and `b`, with the corner between them rounded over `width`.
        static func smoothMax(_ a: Double, _ b: Double, width: Double) -> Double {
            let h = max(width - abs(a - b), 0) / width
            return max(a, b) + h * h * width / 4
        }

        /// Smaller of `a` and `b`, with the corner between them rounded over `width`.
        static func smoothMin(_ a: Double, _ b: Double, width: Double) -> Double {
            -smoothMax(-a, -b, width: width)
        }

        /// A cone at `slope` whose tip is rounded off within about `tipRadius` of the center.
        static func roundedCone(peak: Double, slope: Double, radius: Double, tipRadius: Double) -> Double {
            peak - slope * ((radius * radius + tipRadius * tipRadius).squareRoot() - tipRadius)
        }

        /// Faint, fixed unevenness across a surface (about ±1 unit), deliberately lopsided so heaps aren't mirror-perfect.
        static func roughness(at offset: Double) -> Double {
            0.45 * sin(offset * 0.83 + 1.3) + 0.3 * sin(offset * 2.1 + 0.4) + 0.2 * sin(offset * 4.7 + 2.2)
        }
    }

    static func topCrater(progress: Double, settledProgress: Double) -> TopCrater {
        let level = geometry.topSandHeight(progress: min(max(0, settledProgress), progress))
        return TopCrater(level: level, tip: craterTip(volume: geometry.sandVolume * (1 - progress), flatLevel: level))
    }

    /// How much of the falling sand's sound is grains striking glass rather than sand (0...1), given how much has fallen.
    /// The first grains hit the bare bottom; once a small cone forms the stream lands on sand, though grains rolling off
    /// the cone still tick against the uncovered glass until the pile spreads to the walls.
    static func pourGlassiness(progress: Double) -> Double {
        let peak = pilePeak(volume: geometry.sandVolume * max(0, progress))
        let direct = max(0, 1 - peak / 6)
        let rolling = 0.25 * max(0, 1 - (peak / reposeSlope) / G.innerRadius(G.halfLength))
        return min(1, direct + rolling)
    }

    // MARK: Sand during a flip

    struct Point: Equatable {
        var x: Double
        var y: Double
    }

    /// Interior outline of one bulb, from the neck out to the cap.
    static func bulbPolygon(upper: Bool) -> [Point] { upper ? upperBulb : lowerBulb }
    private static let upperBulb = makeBulb(upper: true)
    private static let lowerBulb = makeBulb(upper: false)

    private static func makeBulb(upper: Bool) -> [Point] {
        let sign = upper ? -1.0 : 1.0
        let distances = Array(stride(from: 0.0, to: G.halfLength, by: 2)) + [G.halfLength]
        let right = distances.map { Point(x: centerX + G.innerRadius($0), y: neckY + sign * $0) }
        return right + right.reversed().map { Point(x: 2 * centerX - $0.x, y: $0.y) }
    }

    /// The part of `polygon` on the downhill side of a surface: points p with p · gravity ≥ offset.
    static func clip(_ polygon: [Point], gravity g: Point, offset: Double) -> [Point] {
        guard let last = polygon.last else { return [] }
        func side(_ p: Point) -> Double { p.x * g.x + p.y * g.y - offset }
        var result: [Point] = []
        var previous = last
        for current in polygon {
            let a = side(previous), b = side(current)
            if (a >= 0) != (b >= 0) {
                let t = a / (a - b)
                result.append(Point(x: previous.x + (current.x - previous.x) * t, y: previous.y + (current.y - previous.y) * t))
            }
            if b >= 0 { result.append(current) }
            previous = current
        }
        return result
    }

    static func area(_ polygon: [Point]) -> Double {
        guard polygon.count > 2 else { return 0 }
        var sum = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Where a flat surface perpendicular to `gravity` must sit so `area` of the bulb lies below it.
    static func surfaceOffset(_ polygon: [Point], gravity g: Point, area target: Double) -> Double {
        let dots = polygon.map { $0.x * g.x + $0.y * g.y }
        guard let low = dots.min(), let high = dots.max() else { return 0 }
        // Raising the offset shrinks the sand region.
        return bisect(low, high) { area(clip(polygon, gravity: g, offset: $0)) > target }
    }

    /// Area (as drawn) of sand resting flat in a bulb, its surface `distance` from the neck.
    static func flatSandArea(upper: Bool, surfaceDistance distance: Double) -> Double {
        let polygon = bulbPolygon(upper: upper)
        return area(clip(polygon, gravity: Point(x: 0, y: 1), offset: neckY + (upper ? -distance : distance)))
    }

    /// Sand outlines in both bulbs, and the direction gravity points in the glass's frame (unit vector).
    struct SettledSand {
        var upper: [Point]
        var lower: [Point]
        var gravity: Point
    }

    /// Sand in each bulb with a flat surface perpendicular to gravity, which points `gravityAngle` radians
    /// from straight down in the glass's frame.
    static func settledSand(gravityAngle: Double, upperArea: Double, lowerArea: Double) -> SettledSand {
        let g = Point(x: sin(gravityAngle), y: cos(gravityAngle))
        func sand(upper: Bool, area target: Double) -> [Point] {
            guard target > 0.5 else { return [] }
            let polygon = bulbPolygon(upper: upper)
            return clip(polygon, gravity: g, offset: surfaceOffset(polygon, gravity: g, area: target))
        }
        return SettledSand(upper: sand(upper: true, area: upperArea), lower: sand(upper: false, area: lowerArea), gravity: g)
    }

    /// How far the sand has slid (0...1) when the glass has tilted `angle` of the way to `fullAngle`.
    /// Nil until the tilt passes the slide threshold; after that the sand lags the glass, avalanching along the wall.
    private static func slide(angle: Double, fullAngle: Double) -> Double? {
        guard angle > slideThreshold else { return nil }
        let t = min(1, (angle - slideThreshold) / (fullAngle - slideThreshold))
        return t * t * (3 - 2 * t)
    }

    /// Sand in each bulb (in the glass's own frame) while a flip that began at `progress` has turned the glass
    /// `angle` radians. Nil before the sand lets go. Each bulb's amount of sand eases from its flat resting area
    /// before the flip to its flat resting area after it.
    static func turningSand(angle: Double, progress p: Double) -> SettledSand? {
        guard let slide = slide(angle: angle, fullAngle: .pi) else { return nil }
        let geo = geometry
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * slide }
        // After the turn the upper bulb is the lower one, and vice versa.
        return settledSand(
            gravityAngle: .pi * slide,
            upperArea: lerp(flatSandArea(upper: true, surfaceDistance: geo.topSandHeight(progress: p)),
                            flatSandArea(upper: false, surfaceDistance: geo.bottomSurfaceDistance(progress: 1 - p))),
            lowerArea: lerp(flatSandArea(upper: false, surfaceDistance: geo.bottomSurfaceDistance(progress: p)),
                            flatSandArea(upper: true, surfaceDistance: geo.topSandHeight(progress: 1 - p))))
    }

    /// Sand while the glass is tipped `angle` radians (up to a quarter turn either way; positive topples clockwise)
    /// onto its side to pause it. Lying down, nothing can pass the neck: each bulb keeps its own sand, spread along
    /// the lower wall.
    static func lyingSand(angle: Double, progress p: Double) -> SettledSand? {
        guard let slide = slide(angle: abs(angle), fullAngle: .pi / 2) else { return nil }
        return settledSand(
            gravityAngle: (angle < 0 ? -1 : 1) * .pi / 2 * slide,
            upperArea: flatSandArea(upper: true, surfaceDistance: geometry.topSandHeight(progress: p)),
            lowerArea: flatSandArea(upper: false, surfaceDistance: geometry.bottomSurfaceDistance(progress: p)))
    }

    /// Half the height of the timer's outline (caps included) when tilted `angle` radians:
    /// how far its center sits above the ground it rests on, in drawing units.
    static func restingHalfHeight(angle: Double) -> Double { outlineHalfWidth * abs(sin(angle)) + 200 * abs(cos(angle)) }

    /// Half the width of the timer's widest part, the round base discs (186 units across). Lying on its side,
    /// the timer rests on their edges.
    static let outlineHalfWidth = 93.0

    /// Where the timer's center sits relative to the bottom corner it pivots on while toppling over, in drawing units
    /// with y up. `side` is +1 when it topples clockwise (to the right, pivoting on its bottom-right corner), -1 to the left.
    static func centerFromPivot(angle: Double, side: Double) -> (x: Double, y: Double) {
        let x = -outlineHalfWidth * side, y = 200.0
        return (x * cos(angle) + y * sin(angle), -x * sin(angle) + y * cos(angle))
    }

    /// How strong the timer's shadow on the ground is (1 = resting on it), given how far above the ground its lowest
    /// point is, in drawing units. A lifted object's shadow fades quickly, so a timer floating mid-screen casts none.
    static func shadowStrength(heightAboveGround height: Double) -> Double {
        let t = min(1, max(0, (height - 0.5) / 80))
        return 1 - t * t * (3 - 2 * t)
    }

    /// Half the width of the timer's outline when tilted `angle` radians, in drawing units.
    static func restingHalfWidth(angle: Double) -> Double { outlineHalfWidth * abs(cos(angle)) + 200 * abs(sin(angle)) }

    /// The nearest center that keeps an outline of the given half size inside `box` (minX, maxX, minY, maxY),
    /// the way a solid object in a box stops at its walls.
    static func keptInside(x: Double, y: Double, halfWidth: Double, halfHeight: Double,
                           box: (minX: Double, maxX: Double, minY: Double, maxY: Double)) -> (x: Double, y: Double) {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
            low > high ? (low + high) / 2 : min(max(value, low), high)
        }
        return (clamp(x, box.minX + halfWidth, box.maxX - halfWidth), clamp(y, box.minY + halfHeight, box.maxY - halfHeight))
    }

    // MARK: Helpers

    /// Midpoint-rule integral of `f` from 0 to `upper`, with a partial last slice so the result is continuous.
    private static func integrate(upTo upper: Double, _ f: (Double) -> Double) -> Double {
        guard upper > 0 else { return 0 }
        var total = 0.0
        var start = 0.0
        while start < upper {
            let end = min(start + sliceHeight, upper)
            total += f((start + end) / 2) * (end - start)
            start = end
        }
        return total
    }

    /// Finds the boundary where `isBelow` switches from true to false.
    private static func bisect(_ low: Double, _ high: Double, isBelow: (Double) -> Bool) -> Double {
        var low = low, high = high
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if isBelow(mid) { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}

/// The timer falling to the bottom of the screen when it's let go, landing with a small bounce.
/// Heights are screen points with y growing upward, like AppKit window positions.
struct Drop {
    static let gravity = 3000.0
    /// Fraction of the landing speed kept on each bounce.
    static let restitution = 0.3
    /// Bounces slower than this just settle.
    static let minBounceSpeed = 80.0

    let floor: Double
    private(set) var y: Double
    private(set) var velocity = 0.0
    private(set) var isResting: Bool
    /// Speed (points per second) of a landing that happened during the last step, if any.
    private(set) var impactSpeed: Double?

    /// Starting at or below the floor (dropped onto the Dock), it simply rests on the floor.
    init(y: Double, floor: Double) {
        self.floor = floor
        self.y = max(y, floor)
        isResting = y <= floor
    }

    mutating func step(dt: Double) {
        impactSpeed = nil
        guard !isResting else { return }
        velocity -= Self.gravity * dt
        y += velocity * dt
        guard y <= floor else { return }
        y = floor
        impactSpeed = -velocity
        let rebound = -velocity * Self.restitution
        if rebound < Self.minBounceSpeed {
            velocity = 0
            isResting = true
        } else {
            velocity = rebound
        }
    }
}

/// How far the falling stream bends when the timer is moved sharply sideways. The glass moves rigidly with the hand
/// and the heaps are held by friction, but grains in mid-air aren't attached to anything: in the timer's frame,
/// gravity seems to tilt away from the acceleration, so the stream swings the other way for a moment.
struct StreamLean {
    static let maxAngle = 0.3
    /// Seconds for grains already in flight to be replaced by ones following the new direction.
    static let response = 0.1

    /// Lean from vertical in radians; positive leans the bottom of the stream to the right.
    private(set) var angle = 0.0

    var isSettled: Bool { angle == 0 }

    /// `acceleration` is the timer's sideways acceleration in points per second squared (positive = right).
    mutating func step(acceleration: Double, timerHeightPoints: Double, dt: Double) {
        let physical = acceleration * SandPhysics.timerHeightMeters / timerHeightPoints
        let target = max(-Self.maxAngle, min(Self.maxAngle, -atan(physical / SandPhysics.earthGravity)))
        angle += (target - angle) * min(1, dt / Self.response)
        if acceleration == 0 && abs(angle) < 0.0005 { angle = 0 }
    }
}

/// How stirred up the sand is: 0 = still, 1 = grains leaping off the heaps.
/// Friction holds a heap until the glass accelerates harder than the sand's slope can resist (g · tan(repose));
/// shaking beyond that, or the jolt of landing after a drop, throws grains up and shakes the heaps flatter.
struct Agitation {
    /// Impact speed (m/s) that sets the sand fully leaping: a fall of about 45 cm.
    static let fullImpactSpeed = 3.0
    /// Seconds for the grains to settle once the jolting stops.
    static let settleTime = 0.35

    static var holdingAcceleration: Double { SandPhysics.earthGravity * SandPhysics.reposeSlope }

    private(set) var level = 0.0

    var isSettled: Bool { level == 0 }

    /// `acceleration` is the size of the timer's physical acceleration in m/s².
    mutating func shake(acceleration: Double) {
        let excess = acceleration - Self.holdingAcceleration
        guard excess > 0 else { return }
        level = max(level, min(1, excess / (2 * SandPhysics.earthGravity)))
    }

    /// `speed` is the physical speed (m/s) at which the timer hit the ground.
    mutating func impact(speed: Double) {
        level = max(level, min(1, speed / Self.fullImpactSpeed))
    }

    mutating func step(dt: Double) {
        level *= exp(-dt / Self.settleTime)
        if level < 0.01 { level = 0 }
    }

    /// The real-world impact speed for a window that landed at `windowSpeed` (points/s) under `Drop.gravity`:
    /// the same fall height, but under real gravity, on a timer where one point is `metersPerPoint`.
    static func impactSpeed(windowSpeed: Double, metersPerPoint: Double) -> Double {
        windowSpeed * (SandPhysics.earthGravity * metersPerPoint / Drop.gravity).squareRoot()
    }
}

// MARK: - Tilting by hand

extension SandPhysics {
    /// The steepest the timer can lean on a base edge and still fall back upright. Past this its center of mass is
    /// beyond the edge and it topples: about 25° for a 400-unit-tall timer on 186-unit base discs.
    static var tippingAngle: Double { atan(outlineHalfWidth / 200) }

    /// How far the timer leans (radians, positive = clockwise on screen) when the middle of its top cap is pushed
    /// `shift` drawing units sideways, pivoting on the bottom corner on the side it's pushed toward.
    static func tiltAngle(forTopShift shift: Double) -> Double {
        let side: Double = shift < 0 ? -1 : 1
        // The top cap's middle sits `reach` from the pivot corner, `lean0` radians inward from straight up.
        let reach = (outlineHalfWidth * outlineHalfWidth + 400 * 400).squareRoot()
        let lean0 = atan2(outlineHalfWidth, 400)
        let s = min(1, max(-1, (abs(shift) - outlineHalfWidth) / reach))
        return side * min(.pi / 2, max(0, lean0 + asin(s)))
    }

    /// Where the middle of the top cap is relative to the corner the timer leans or lies on (drawing units, y up), when
    /// it's tilted `angle` radians about the bottom corner on `side`.
    static func topCapFromPivot(angle: Double, side: Double) -> (x: Double, y: Double) {
        let x = -outlineHalfWidth * side, y = 377.0
        return (x * cos(angle) + y * sin(angle), -x * sin(angle) + y * cos(angle))
    }

    /// How far a timer leans once a hand holding its top cap has swept `handSweep` radians around the pivot corner
    /// (counterclockwise positive, as screen angles go), starting from `start`. The timer points toward the hand, and can
    /// go no further than lying flat or standing upright on that corner.
    static func leanAngle(startingAt start: Double, handSweep: Double, side: Double) -> Double {
        let angle = start - handSweep
        return side > 0 ? min(.pi / 2, max(0, angle)) : max(-.pi / 2, min(0, angle))
    }

    /// Angular acceleration (rad/s²) gravity gives the timer when it leans on an edge, per unit of sin(lean left before
    /// the tipping point): g × (distance from the pivot to the center of mass) ÷ (moment of inertia per unit mass) for a
    /// 15 cm solid block, slowed about 3× in time like the drop, so the rocking is visible.
    static var rockingStrength: Double {
        let metersPerUnit = timerHeightMeters / 400
        let width = 2 * outlineHalfWidth * metersPerUnit, height = timerHeightMeters
        let pivotToCenter = (outlineHalfWidth * outlineHalfWidth + 200 * 200).squareRoot() * metersPerUnit
        return earthGravity * pivotToCenter * 3 / (width * width + height * height) / 9
    }

    /// Lets a sand surface slump wherever tilting the glass by `tilt` (radians, clockwise on screen) has made it steeper
    /// than sand can hold, moving sand downhill between neighbouring columns. `heights` are surface heights (upward) at
    /// evenly spaced columns `spacing` apart. Sand is conserved and slopes that aren't too steep are left alone, so the
    /// uphill side of a heap stays put. Each iteration moves a little sand, so a few per frame show the slump happening.
    static func relaxSlopes(_ heights: [Double], spacing: Double, tilt: Double, iterations: Int) -> [Double] {
        var h = heights
        guard h.count > 1 else { return h }
        let repose = atan(reposeSlope), slack = 0.02, limit = Double.pi / 2 - 0.05
        // Seen upright, a surface segment at angle a (rising to the right) is at a − tilt.
        let steepestRise = spacing * tan(min(limit, tilt + repose + slack))
        let steepestFall = spacing * tan(max(-limit, tilt - repose - slack))
        for _ in 0..<iterations {
            for i in 0..<(h.count - 1) {
                let step = h[i + 1] - h[i]
                if step > steepestRise {
                    let moved = (step - steepestRise) / 2
                    h[i + 1] -= moved
                    h[i] += moved
                } else if step < steepestFall {
                    let moved = (steepestFall - step) / 2
                    h[i] -= moved
                    h[i + 1] += moved
                }
            }
        }
        return h
    }

    /// Columns used to remember how a heap has slumped, across the inside of a bulb.
    static let slumpColumns = 49
    static let slumpHalfWidth = 52.0

    static var slumpColumnOffsets: [Double] {
        (0..<slumpColumns).map { -slumpHalfWidth + 2 * slumpHalfWidth * Double($0) / Double(slumpColumns - 1) }
    }

    /// How much a slumped heap's surface is raised or lowered at `offset` from the center, from per-column `changes`.
    static func slump(_ changes: [Double], at offset: Double) -> Double {
        guard changes.count == slumpColumns, abs(offset) <= slumpHalfWidth else { return 0 }
        let position = (offset + slumpHalfWidth) / (2 * slumpHalfWidth) * Double(slumpColumns - 1)
        let i = min(slumpColumns - 2, Int(position))
        return changes[i] + (changes[i + 1] - changes[i]) * (position - Double(i))
    }
}

/// A timer let go while leaning on a base edge, short of its tipping point: gravity swings it back upright, and it
/// lands on its base with a clack and a small rebound or two before settling.
struct Rocking {
    static let restitution = 0.35
    /// Rebounds slower than this (rad/s) just settle.
    static let settleSpeed = 0.25

    private(set) var angle: Double
    private(set) var velocity = 0.0
    /// Angular speed of a landing on the base during the last step, if any.
    private(set) var impactSpeed: Double?

    init(angle: Double) { self.angle = angle }

    var isSettled: Bool { angle == 0 && velocity == 0 }
    var hasToppled: Bool { abs(angle) >= SandPhysics.tippingAngle }

    mutating func step(dt: Double) {
        impactSpeed = nil
        guard !isSettled, !hasToppled else { return }
        let side: Double = angle < 0 ? -1 : 1
        velocity -= side * SandPhysics.rockingStrength * sin(SandPhysics.tippingAngle - abs(angle)) * dt
        angle += velocity * dt
        guard angle == 0 || (angle < 0) != (side < 0) else { return }
        // Back on its base: it lands, and may rebound a little onto the same edge.
        impactSpeed = abs(velocity)
        let rebound = abs(velocity) * Self.restitution
        angle = 0
        velocity = rebound < Self.settleSpeed ? 0 : side * rebound
        if velocity != 0 { angle = side * 1e-6 }
    }
}
