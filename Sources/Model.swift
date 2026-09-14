import Foundation

/// Timekeeping for the hourglass. `progress` is the fraction of sand in the lower bulb (0 = all on top).
struct SandClock {
    private(set) var duration: TimeInterval
    private(set) var storedProgress: Double
    private(set) var runningSince: Date?
    /// Progress when sand last started flowing from a settled heap (a flip or restart). The top crater grows from here.
    private(set) var flowStartProgress: Double

    /// A fresh timer sits with all its sand at the bottom, waiting to be flipped.
    init(duration: TimeInterval, progress: Double = 1, runningSince: Date? = nil, flowStartProgress: Double? = nil) {
        self.duration = duration
        self.storedProgress = progress
        self.runningSince = runningSince
        self.flowStartProgress = flowStartProgress ?? progress
    }

    /// When the top bulb empties, if the sand is flowing.
    var finishTime: Date? {
        runningSince.map { $0.addingTimeInterval((1 - storedProgress) * duration) }
    }

    func progress(at now: Date) -> Double {
        guard let since = runningSince else { return storedProgress }
        return min(1, storedProgress + now.timeIntervalSince(since) / duration)
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
        flowStartProgress = storedProgress
        runningSince = now
    }

    mutating func restart(at now: Date) {
        storedProgress = 0
        flowStartProgress = 0
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

    static func outerRadius(_ distance: Double) -> Double {
        let d = abs(distance)
        guard d > neckHalf else { return neckRadius }
        let u = min(1, (d - neckHalf) / (taperLength - neckHalf))
        let easeOut = 1 - pow(1 - u, 2.5)
        let smooth = u * u * (3 - 2 * u)
        return neckRadius + (bulbRadius - neckRadius) * (0.6 * easeOut + 0.4 * smooth)
    }

    static func innerRadius(_ distance: Double) -> Double { max(1.2, outerRadius(distance) - wall) }

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
