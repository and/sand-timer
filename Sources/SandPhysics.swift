import Foundation

/// How the sand physically behaves, in the renderer's 200 x 400 unit space
/// (neck at x = 100, y = 200; y grows downward). Pure functions, so it can be tested without AppKit.
enum SandPhysics {
    typealias G = HourglassGeometry
    static let geometry = HourglassGeometry()

    static let centerX = 100.0
    static let neckY = 200.0
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

    /// Sand in each bulb (in the glass's own frame) while a flip that began at `progress` has turned the glass
    /// `angle` radians. Nil before the sand lets go. The surface stays perpendicular to where gravity points,
    /// lagging behind the glass so the sand avalanches along the wall, and each bulb's amount of sand
    /// eases from its flat resting area before the flip to its flat resting area after it.
    static func turningSand(angle: Double, progress p: Double) -> (upper: [Point], lower: [Point])? {
        guard angle > slideThreshold else { return nil }
        let t = min(1, (angle - slideThreshold) / (.pi - slideThreshold))
        let slide = t * t * (3 - 2 * t)
        let g = Point(x: sin(.pi * slide), y: cos(.pi * slide))
        let geo = geometry
        func sand(upper: Bool, from start: Double, to end: Double) -> [Point] {
            let target = start + (end - start) * slide
            guard target > 0.5 else { return [] }
            let polygon = bulbPolygon(upper: upper)
            return clip(polygon, gravity: g, offset: surfaceOffset(polygon, gravity: g, area: target))
        }
        // After the turn the upper bulb is the lower one, and vice versa.
        return (
            sand(upper: true,
                 from: flatSandArea(upper: true, surfaceDistance: geo.topSandHeight(progress: p)),
                 to: flatSandArea(upper: false, surfaceDistance: geo.bottomSurfaceDistance(progress: 1 - p))),
            sand(upper: false,
                 from: flatSandArea(upper: false, surfaceDistance: geo.bottomSurfaceDistance(progress: p)),
                 to: flatSandArea(upper: true, surfaceDistance: geo.topSandHeight(progress: 1 - p)))
        )
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

    /// Starting at or below the floor (dropped onto the Dock), it simply rests on the floor.
    init(y: Double, floor: Double) {
        self.floor = floor
        self.y = max(y, floor)
        isResting = y <= floor
    }

    mutating func step(dt: Double) {
        guard !isResting else { return }
        velocity -= Self.gravity * dt
        y += velocity * dt
        guard y <= floor else { return }
        y = floor
        let rebound = -velocity * Self.restitution
        if rebound < Self.minBounceSpeed {
            velocity = 0
            isResting = true
        } else {
            velocity = rebound
        }
    }
}

/// The hourglass swinging on a damped spring when the window is dragged.
struct Sway {
    static let maxTilt = 0.14
    static let stiffness = 120.0
    static let damping = 5.5
    /// Tilt per unit of sideways acceleration (points per second squared).
    static let inertia = 0.0056
    /// Seconds the sand surface takes to catch up with the glass.
    static let sandLag = 0.08

    private(set) var tilt = 0.0
    private(set) var velocity = 0.0
    private(set) var sandTilt = 0.0

    var isSettled: Bool { abs(tilt) < 0.0005 && abs(velocity) < 0.002 && abs(sandTilt) < 0.0005 }

    mutating func step(acceleration: Double, dt: Double) {
        let torque = -Self.stiffness * tilt - Self.damping * velocity + Self.inertia * acceleration
        velocity += torque * dt
        tilt += velocity * dt
        if abs(tilt) > Self.maxTilt {
            tilt = tilt > 0 ? Self.maxTilt : -Self.maxTilt
            velocity = 0
        }
        sandTilt += (tilt - sandTilt) * min(1, dt / Self.sandLag)
        if isSettled && acceleration == 0 { self = Sway() }
    }
}
