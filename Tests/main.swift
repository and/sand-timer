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

// Remaining time shown on the base.
let thirty = SandClock(duration: 1800)
check(thirty.remainingLabel(progress: 0) == "30:00", "full timer")
check(thirty.remainingLabel(progress: 1) == "30:00", "when the sand has run out, shows what the timer holds")
check(thirty.remainingLabel(progress: 0.5) == "15:00", "exact half")
check(thirty.remainingLabel(progress: 61.0 / 1800) == "28:59", "after a minute and a second")
check(thirty.remainingLabel(progress: 0.9999) == "0:01", "the last second counts down to 0:01")
check(SandClock(duration: 3600).remainingLabel(progress: 0) == "60:00", "an hour")

var two = SandClock(duration: 120)
two.restart(at: t0)
check(two.remainingLabel(progress: two.progress(at: at(50))) == "1:10", "2-min timer at 50s")
two.flip(at: at(50))
check(two.remainingLabel(progress: two.progress(at: at(50))) == "0:50", "flipping at 50s leaves 50s on top")
check(two.remainingLabel(progress: two.progress(at: at(99.5))) == "0:01", "flipped timer is about to finish after 50s")
check(two.remainingLabel(progress: two.progress(at: at(100))) == "2:00", "once finished, back to showing its full two minutes")

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

check(P.pourGlassiness(progress: 0) == 1, "the first grains strike the bare glass bottom")
check(P.pourGlassiness(progress: 0.05) < 0.5, "once a cone has formed, the stream mostly lands on sand")
check(P.pourGlassiness(progress: 0.6) == 0, "a pile covering the bottom leaves no glass to hit")
var lastGlassiness = 1.0
for i in 0...40 {
    let g = P.pourGlassiness(progress: Double(i) / 40)
    check(g <= lastGlassiness + 1e-12, "the sound only gets softer as sand builds up")
    lastGlassiness = g
}
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

// Pausing lays the timer on its side.
check(P.lyingSand(angle: 0.3, progress: 0.4) == nil, "sand holds still as the timer starts to tip")
check(near(P.restingHalfHeight(angle: 0), 200) && near(P.restingHalfHeight(angle: .pi / 2), 93),
      "lying down, the timer rests on the edge of its base discs")
for p in [0.2, 0.7] {
    guard let lying = P.lyingSand(angle: .pi / 2, progress: p) else { check(false, "lying sand exists"); continue }
    let upperArea = P.flatSandArea(upper: true, surfaceDistance: geo.topSandHeight(progress: p))
    let lowerArea = P.flatSandArea(upper: false, surfaceDistance: geo.bottomSurfaceDistance(progress: p))
    check(relNear(P.area(lying.upper), upperArea, 1e-2) && relNear(P.area(lying.lower), lowerArea, 1e-2),
          "on its side each bulb keeps its own sand at \(p)")
    let meanX = lying.lower.map(\.x).reduce(0, +) / Double(lying.lower.count)
    check(meanX > P.centerX + 10, "the sand lies along the wall that's now underneath at \(p)")
    check(lying.upper.allSatisfy { $0.y <= P.neckY + 1e-6 } && lying.lower.allSatisfy { $0.y >= P.neckY - 1e-6 },
          "no sand crosses the neck while lying down at \(p)")
}

// Knocked over, it topples about its bottom corner to whichever side it falls.
let rightStart = P.centerFromPivot(angle: 0, side: 1), rightEnd = P.centerFromPivot(angle: .pi / 2, side: 1)
check(near(rightStart.x, -93) && near(rightStart.y, 200), "standing, the center is up and in from the right corner")
check(near(rightEnd.x, 200) && near(rightEnd.y, 93), "toppled right, it lies to the right of that corner")
let leftEnd = P.centerFromPivot(angle: -.pi / 2, side: -1)
check(near(leftEnd.x, -200) && near(leftEnd.y, 93), "toppled left, it lies to the left of its left corner")
for a in stride(from: 0.0, through: .pi / 2, by: 0.2) {
    check(near(P.centerFromPivot(angle: a, side: 1).y, P.restingHalfHeight(angle: a), 1e-9), "the pivot corner stays on the ground at \(a)")
}
if let leftLying = P.lyingSand(angle: -.pi / 2, progress: 0.3) {
    let meanX = leftLying.upper.map(\.x).reduce(0, +) / Double(leftLying.upper.count)
    check(meanX < P.centerX - 10, "fallen to the left, the sand lies along the other wall")
} else { check(false, "sand lies down when toppled left") }

// The screen is a box the timer can't leave.
let box = (minX: 0.0, maxX: 1440.0, minY: 0.0, maxY: 870.0)
let inside = P.keptInside(x: 700, y: 400, halfWidth: 100, halfHeight: 200, box: box)
check(inside.x == 700 && inside.y == 400, "free to move inside the box")
let pushed = P.keptInside(x: 1500, y: -50, halfWidth: 100, halfHeight: 200, box: box)
check(pushed.x == 1340 && pushed.y == 200, "stops at the right wall and the floor")
let ceiling = P.keptInside(x: 20, y: 900, halfWidth: 100, halfHeight: 200, box: box)
check(ceiling.x == 100 && ceiling.y == 670, "stops at the left wall and the ceiling")
check(near(P.restingHalfWidth(angle: 0), 93) && near(P.restingHalfWidth(angle: .pi / 2), 200),
      "standing it's as wide as its base discs; lying down, as wide as it is tall")

// Moving the timer sharply bends the falling stream, never the glass.
var lean = StreamLean()
for _ in 0..<60 { lean.step(acceleration: 3_000, timerHeightPoints: 300, dt: 1.0 / 60) }
check(lean.angle < 0, "accelerating right leaves the stream trailing to the left")
check(near(lean.angle, -atan(3_000 * SandPhysics.timerHeightMeters / 300 / SandPhysics.earthGravity), 1e-3),
      "steady acceleration bends it by the tilt of apparent gravity")
for _ in 0..<60 { lean.step(acceleration: 1_000_000, timerHeightPoints: 300, dt: 1.0 / 60) }
check(abs(lean.angle) <= StreamLean.maxAngle, "bend is limited")
for _ in 0..<(60 * 2) { lean.step(acceleration: 0, timerHeightPoints: 300, dt: 1.0 / 60) }
check(lean.isSettled, "stream hangs straight again once the timer stops accelerating")

// Gravity on the window.
var drop = Drop(y: 700, floor: 50)
check(!drop.isResting, "a raised timer starts falling")
var lowest = drop.y, bounced = false, steps = 0
while !drop.isResting && steps < 60 * 10 {
    drop.step(dt: 1.0 / 60)
    lowest = min(lowest, drop.y)
    if drop.velocity > 0 { bounced = true }
    steps += 1
}
check(drop.isResting && drop.y == 50, "comes to rest on the floor")
check(lowest >= 50, "never sinks below the floor")
check(bounced, "bounces a little on landing")
check(Double(steps) / 60 < 1.5, "settles quickly")
var impacts: [Double] = []
var bouncing = Drop(y: 650, floor: 50)
while !bouncing.isResting { bouncing.step(dt: 1.0 / 240); if let v = bouncing.impactSpeed { impacts.append(v) } }
check(relNear(impacts.first ?? 0, (2 * Drop.gravity * 600).squareRoot(), 0.02), "first landing speed matches the drop height")
check(impacts.count >= 2 && impacts[1] < impacts[0] * 0.5, "each bounce lands softer")
let fromDock = Drop(y: 20, floor: 50)
check(fromDock.isResting && fromDock.y == 50, "let go below the floor, it sits on the floor")

// Shaking and landing stir up the sand.
var stirred = Agitation()
stirred.shake(acceleration: 3)
check(stirred.isSettled, "a gentle move doesn't disturb the heaps")
stirred.shake(acceleration: 15)
check(stirred.level > 0 && stirred.level < 1, "a hard shake sets grains moving")
for _ in 0..<(60 * 3) { stirred.step(dt: 1.0 / 60) }
check(stirred.isSettled, "grains settle once the shaking stops")
let metersPerPoint = SandPhysics.timerHeightMeters / 300
func landing(fromHeight points: Double) -> Double {
    var a = Agitation()
    a.impact(speed: Agitation.impactSpeed(windowSpeed: (2 * Drop.gravity * points).squareRoot(), metersPerPoint: metersPerPoint))
    return a.level
}
check(relNear(Agitation.impactSpeed(windowSpeed: (2 * Drop.gravity * 400).squareRoot(), metersPerPoint: metersPerPoint),
              (2 * SandPhysics.earthGravity * 400 * metersPerPoint).squareRoot()),
      "impact speed is what a real fall from that height would give")
check(landing(fromHeight: 20) < landing(fromHeight: 200) && landing(fromHeight: 200) < landing(fromHeight: 800),
      "a higher drop jolts the sand harder")
check(landing(fromHeight: 5000) == 1, "jolt is capped")

if failures == 0 { print("All tests passed") } else { print("\(failures) failure(s)"); exit(1) }
