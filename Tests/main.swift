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

if failures == 0 { print("All tests passed") } else { print("\(failures) failure(s)"); exit(1) }
