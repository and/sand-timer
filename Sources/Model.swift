import Foundation

/// Timekeeping for the hourglass. `progress` is the fraction of sand in the lower bulb (0 = all on top).
struct SandClock {
    private(set) var duration: TimeInterval
    private(set) var storedProgress: Double
    private(set) var runningSince: Date?

    /// A fresh timer sits with all its sand at the bottom, waiting to be flipped.
    init(duration: TimeInterval, progress: Double = 1, runningSince: Date? = nil) {
        self.duration = duration
        self.storedProgress = progress
        self.runningSince = runningSince
    }

    /// When the top bulb empties, if the sand is flowing.
    var finishTime: Date? {
        runningSince.map { $0.addingTimeInterval((1 - storedProgress) * duration) }
    }

    func progress(at now: Date) -> Double {
        guard let since = runningSince else { return storedProgress }
        return min(1, storedProgress + max(0, now.timeIntervalSince(since)) / duration)
    }

    /// Lets extra sand through (positive) or holds sand back (negative), `seconds` worth at the normal rate, for when
    /// the sand feels stronger or weaker gravity than usual. Only while sand is flowing.
    mutating func shiftFlow(by seconds: Double) {
        guard let since = runningSince else { return }
        runningSince = since.addingTimeInterval(-seconds)
    }

    func isRunning(at now: Date) -> Bool { runningSince != nil && progress(at: now) < 1 }

    func isPaused(at now: Date) -> Bool { runningSince == nil && progress(at: now) < 1 }

    func remaining(at now: Date) -> TimeInterval { (1 - progress(at: now)) * duration }

    /// Time left as m:ss, printed on the base, rounded up. Once the sand has run out (or before the first flip)
    /// it shows the full duration instead, like the printed label on a real timer: what a flip will give you.
    func remainingLabel(progress: Double) -> String {
        let left = progress >= 1 ? duration : (1 - progress) * duration
        let seconds = max(1, Int((left - 1e-9).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Turning the glass over: whatever had fallen is now on top.
    mutating func flip(at now: Date) {
        storedProgress = 1 - progress(at: now)
        runningSince = now
    }

    mutating func restart(at now: Date) {
        storedProgress = 0
        runningSince = now
    }

    mutating func pause(at now: Date) {
        storedProgress = progress(at: now)
        runningSince = nil
    }

    mutating func resume(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    /// Changes the duration while keeping the sand where it is.
    mutating func setDuration(_ newDuration: TimeInterval, at now: Date) {
        storedProgress = progress(at: now)
        if runningSince != nil { runningSince = now }
        duration = newDuration
    }
}

/// Shape of the glass in drawing units (the whole timer is 200 x 400, neck at y = 200),
/// and the volume math that turns a sand fraction into fill heights.
struct HourglassGeometry {
    static let halfLength = 154.0     // visible glass from the neck to a cap
    static let bulbRadius = 55.0
    static let neckRadius = 4.5
    static let neckHalf = 3.0
    static let taperLength = 68.0     // neck to where the bulb becomes a straight cylinder
    static let wall = 2.2
    static let sandFullHeight = 76.0  // sand column above the neck when all sand is on top
    static let step = 0.25

    /// cumulative[i] = interior volume from the neck out to distance i * step.
    private let cumulative: [Double]

    init() {
        let n = Int(Self.halfLength / Self.step)
        var c = [0.0]
        c.reserveCapacity(n + 1)
        var prev = Self.innerRadius(0)
        for i in 1...n {
            let r = Self.innerRadius(Double(i) * Self.step)
            c.append(c[i - 1] + Double.pi * (prev * prev + r * r) / 2 * Self.step)
            prev = r
        }
        cumulative = c
    }

    /// `neckScale` sets the size of the opening sand pours through (short timers need a wider one); the bulbs stay the same.
    /// Short timers get a wider waist. Long ones keep the standard waist, which a real glass needs to stay sturdy,
    /// and instead have thicker glass at the pinch around a narrower bore (see `innerRadius`).
    static func outerRadius(_ distance: Double, neckScale: Double = 1) -> Double {
        let d = abs(distance)
        let neck = neckRadius * max(1, neckScale)
        guard d > neckHalf else { return neck }
        let u = min(1, (d - neckHalf) / (taperLength - neckHalf))
        let easeOut = 1 - pow(1 - u, 2.5)
        let smooth = u * u * (3 - 2 * u)
        return neck + (bulbRadius - neck) * (0.6 * easeOut + 0.4 * smooth)
    }

    static func innerRadius(_ distance: Double, neckScale: Double = 1) -> Double {
        let plain = outerRadius(distance, neckScale: neckScale) - wall
        guard neckScale < 1 else { return max(1.2 * neckScale, plain) }
        // A narrower bore than the waist allows: the glass thickens toward the pinch, fading out a few units away.
        let bore = (neckRadius - wall) * neckScale
        let extra = (neckRadius - wall) - bore
        return max(bore, plain - extra * exp(-abs(distance) / 6))
    }

    var halfVolume: Double { cumulative[cumulative.count - 1] }
    var sandVolume: Double { volume(upTo: Self.sandFullHeight) }

    func volume(upTo distance: Double) -> Double {
        let x = min(max(distance, 0), Self.halfLength) / Self.step
        let i = min(Int(x), cumulative.count - 2)
        return cumulative[i] + (cumulative[i + 1] - cumulative[i]) * (x - Double(i))
    }

    func distance(forVolume v: Double) -> Double {
        let v = min(max(v, 0), halfVolume)
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] < v { lo = mid } else { hi = mid }
        }
        let span = cumulative[hi] - cumulative[lo]
        let f = span > 0 ? (v - cumulative[lo]) / span : 0
        return (Double(lo) + f) * Self.step
    }

    /// Height of the sand column above the neck in the upper bulb.
    func topSandHeight(progress p: Double) -> Double {
        p >= 1 ? 0 : distance(forVolume: sandVolume * (1 - p))
    }

    /// Distance from the neck down to the (flat-equivalent) sand surface in the lower bulb.
    func bottomSurfaceDistance(progress p: Double) -> Double {
        distance(forVolume: halfVolume - sandVolume * p)
    }
}
