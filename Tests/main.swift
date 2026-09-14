import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL (line \(line)): \(message)") }
}
func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

let t0 = Date(timeIntervalSinceReferenceDate: 0)
func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

// A new timer waits with all sand at the bottom.
var clock = SandClock(duration: 100)
check(clock.progress(at: t0) == 1, "starts finished")
check(!clock.isRunning(at: t0), "starts stopped")
check(!clock.isPaused(at: t0), "finished is not paused")

// Flip starts it; sand falls linearly.
clock.flip(at: t0)
check(clock.progress(at: t0) == 0, "flip from finished puts all sand on top")
check(near(clock.progress(at: at(25)), 0.25), "quarter way")
check(near(clock.remaining(at: at(25)), 75), "remaining seconds")
check(clock.isRunning(at: at(25)), "running mid-way")

// Flipping mid-run swaps top and bottom.
clock.flip(at: at(30))
check(near(clock.progress(at: at(30)), 0.7), "flip mid-run inverts progress")
check(near(clock.progress(at: at(60)), 1), "finishes after the remaining 30s")
check(!clock.isRunning(at: at(60)), "stops when done")
check(clock.progress(at: at(500)) == 1, "progress clamps at 1")

// Flipping a full-top timer instantly empties it (no run).
var full = SandClock(duration: 100)
full.restart(at: t0)
full.flip(at: t0)
check(full.progress(at: t0) == 1 && !full.isRunning(at: t0), "flip of full top is done")

// Pause and resume.
var paused = SandClock(duration: 100)
paused.restart(at: t0)
paused.pause(at: at(40))
check(paused.isPaused(at: at(90)), "paused")
check(near(paused.progress(at: at(90)), 0.4), "pause freezes progress")
paused.resume(at: at(90))
paused.resume(at: at(95)) // no-op while running
check(near(paused.progress(at: at(100)), 0.5), "resume continues from pause")

// Duration change keeps sand in place.
var resized = SandClock(duration: 100)
resized.restart(at: t0)
resized.setDuration(200, at: at(50))
check(near(resized.progress(at: at(50)), 0.5), "duration change keeps progress")
check(near(resized.progress(at: at(150)), 1), "new duration applies to the rest")

// Minute counts shown on the glass.
let thirty = SandClock(duration: 1800)
check(thirty.glassLabels(progress: 0) == ("30", "0"), "full top shows 30 left, 0 elapsed")
check(thirty.glassLabels(progress: 1) == ("0", "30"), "done shows 0 left, 30 elapsed")
check(thirty.glassLabels(progress: 0.5) == ("15", "15"), "exact half")
check(thirty.glassLabels(progress: 10.0 / 1800) == ("30", "0"), "first minute still shows 30 left")
check(thirty.glassLabels(progress: 61.0 / 1800) == ("29", "1"), "after a minute and a second")

// Short timers show seconds, so flipping mid-run doesn't round both halves to the same minute.
var two = SandClock(duration: 120)
two.restart(at: t0)
check(two.glassLabels(progress: two.progress(at: at(50))) == ("1:10", "0:50"), "2-min timer at 50s")
two.flip(at: at(50))
check(two.glassLabels(progress: two.progress(at: at(50))) == ("0:50", "1:10"), "flipped at 50s swaps the labels")
check(two.glassLabels(progress: two.progress(at: at(100))) == ("0:00", "2:00"), "flipped timer finishes after 50s")
check(SandClock(duration: 120).glassLabels(progress: 0) == ("2:00", "0:00"), "full 2-min timer")
check(SandClock(duration: 600).glassLabels(progress: 0) == ("10", "0"), "10 minutes and up shows whole minutes")

// Geometry.
let geo = HourglassGeometry()
check(near(HourglassGeometry.outerRadius(0), HourglassGeometry.neckRadius), "neck radius")
check(near(HourglassGeometry.outerRadius(HourglassGeometry.taperLength), HourglassGeometry.bulbRadius), "bulb radius at end of taper")
check(near(HourglassGeometry.outerRadius(-120), HourglassGeometry.bulbRadius), "profile symmetric")
for d in stride(from: 0.0, through: HourglassGeometry.halfLength, by: 7.3) {
    check(near(geo.distance(forVolume: geo.volume(upTo: d)), d, 1e-3), "volume/distance round-trip at \(d)")
}
check(near(geo.topSandHeight(progress: 0), HourglassGeometry.sandFullHeight, 1e-3), "full top height")
check(geo.topSandHeight(progress: 1) == 0, "empty top")
check(near(geo.bottomSurfaceDistance(progress: 0), HourglassGeometry.halfLength, 1e-3), "empty bottom at cap")
var lastTop = Double.infinity, lastBottom = Double.infinity
for i in 0...20 {
    let p = Double(i) / 20
    let top = geo.topSandHeight(progress: p), bottom = geo.bottomSurfaceDistance(progress: p)
    check(top <= lastTop && bottom <= lastBottom, "levels move monotonically at \(p)")
    lastTop = top; lastBottom = bottom
}
check(geo.bottomSurfaceDistance(progress: 1) > HourglassGeometry.taperLength, "full bottom stays in the cylinder, like the product")

// Flow start and finish time.
var flowing = SandClock(duration: 100)
flowing.restart(at: t0)
check(flowing.flowStartProgress == 0, "restart starts flow from full")
check(flowing.finishTime == at(100), "finish time after restart")
flowing.pause(at: at(30))
flowing.resume(at: at(40))
check(flowing.flowStartProgress == 0, "pause/resume keeps the crater's starting point")
check(flowing.finishTime == at(110), "finish time shifts by the pause")
flowing.flip(at: at(60))
check(near(flowing.flowStartProgress, 0.5), "flip restarts flow from the new top amount")
check(flowing.finishTime == at(110), "finish time after flipping at the halfway mark")
flowing.pause(at: at(70))
check(flowing.finishTime == nil, "no finish time while paused")

// Sand physics.
typealias P = SandPhysics
func relNear(_ a: Double, _ b: Double, _ tolerance: Double = 1e-3) -> Bool { abs(a - b) <= tolerance * max(1, abs(b)) }
let sandTotal = geo.sandVolume
for fraction in [0.001, 0.02, 0.2, 0.6, 1.0] {
    let v = sandTotal * fraction
    check(relNear(P.pileVolume(peak: P.pilePeak(volume: v)), v), "pile holds its volume at \(fraction)")
}
let smallPile = 2_000.0
check(relNear(P.pilePeak(volume: smallPile), pow(3 * P.reposeSlope * P.reposeSlope * smallPile / .pi, 1.0 / 3), 1e-2),
      "a small pile is a free-standing cone")
check(P.pilePeak(volume: sandTotal) < HourglassGeometry.halfLength, "full pile stays below the neck")
var lastPeak = 0.0
for i in 1...20 {
    let peak = P.pilePeak(volume: sandTotal * Double(i) / 20)
    check(peak > lastPeak, "pile grows monotonically")
    lastPeak = peak
}

let flat = geo.topSandHeight(progress: 0)
check(relNear(P.craterTip(volume: P.craterVolume(tip: flat, flatLevel: flat), flatLevel: flat), flat), "no crater before any sand drains")
for fraction in [0.97, 0.7, 0.3, 0.05] {
    let v = P.craterVolume(tip: flat, flatLevel: flat) * fraction
    let tip = P.craterTip(volume: v, flatLevel: flat)
    check(relNear(P.craterVolume(tip: tip, flatLevel: flat), v), "crater leaves the right volume at \(fraction)")
    check(tip < flat, "crater has depth at \(fraction)")
}
// The funnel walls are steeper than sand's slope, so the last sand drains as a shallow cone down in the funnel.
let lastTip = P.craterTip(volume: P.craterVolume(tip: flat, flatLevel: flat) * 0.01, flatLevel: flat)
check(lastTip >= 0 && lastTip < HourglassGeometry.taperLength / 2, "near the end the sand sits low in the funnel")

check(relNear(P.fallDistance(after: 0.25), 150), "stream front falls a bulb length in a quarter second")
check(P.fallDistance(after: -1) == 0, "no fall before release")

let square = [P.Point(x: 0, y: 0), P.Point(x: 10, y: 0), P.Point(x: 10, y: 10), P.Point(x: 0, y: 10)]
check(near(P.area(square), 100), "polygon area")
check(near(P.area(P.clip(square, gravity: P.Point(x: 0, y: 1), offset: 4)), 60), "clip keeps the downhill side")
let diagonal = P.Point(x: sqrt(0.5), y: sqrt(0.5))
check(relNear(P.area(P.clip(square, gravity: diagonal, offset: P.surfaceOffset(square, gravity: diagonal, area: 37))), 37),
      "surface offset matches a target area on a tilt")

check(P.turningSand(angle: 0.3, progress: 0.4) == nil, "sand holds still early in the turn")
for p in [0.0, 0.35, 1.0] {
    let startUpper = P.flatSandArea(upper: true, surfaceDistance: geo.topSandHeight(progress: p))
    let endUpper = P.flatSandArea(upper: false, surfaceDistance: geo.bottomSurfaceDistance(progress: 1 - p))
    if let begin = P.turningSand(angle: P.slideThreshold + 1e-6, progress: p) {
        check(relNear(P.area(begin.upper), startUpper, 1e-2), "turn starts from the resting amount at \(p)")
    } else { check(false, "turning sand exists after the threshold") }
    if let end = P.turningSand(angle: .pi, progress: p) {
        check(relNear(P.area(end.upper), endUpper, 1e-2), "turn ends at the new resting amount at \(p)")
        check(end.upper.allSatisfy { $0.y <= P.neckY + 1e-6 }, "sand stays in its bulb")
        if endUpper > 100 {
            let meanY = end.upper.map(\.y).reduce(0, +) / Double(end.upper.count)
            check(meanY < P.neckY - HourglassGeometry.halfLength / 2, "upside down, the old top sand has fallen to the cap end")
        }
    }
    if let mid = P.turningSand(angle: .pi / 2, progress: p), p == 0.35 {
        check(!mid.upper.isEmpty && !mid.lower.isEmpty, "both bulbs hold sand mid-turn")
    }
}

var sway = Sway()
sway.step(acceleration: 3_000, dt: 1.0 / 60)
check(sway.tilt > 0, "accelerating right tips the glass clockwise")
for _ in 0..<60 { sway.step(acceleration: 60_000, dt: 1.0 / 60) }
check(abs(sway.tilt) <= Sway.maxTilt, "tilt is clamped")
for _ in 0..<(60 * 4) { sway.step(acceleration: 0, dt: 1.0 / 60) }
check(sway.isSettled && sway.tilt == 0, "sway settles back to upright")

if failures == 0 { print("All tests passed") } else { print("\(failures) failure(s)"); exit(1) }
