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
