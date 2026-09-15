import Foundation

private typealias P = SandPhysics
private let geo = HourglassGeometry()

func sandTests() {
    suite("Glass geometry") {
        test("the glass narrows to the neck and is symmetric") {
            expect(near(HourglassGeometry.outerRadius(0), HourglassGeometry.neckRadius))
            expect(near(HourglassGeometry.outerRadius(HourglassGeometry.taperLength), HourglassGeometry.bulbRadius))
            expect(near(HourglassGeometry.outerRadius(-120), HourglassGeometry.outerRadius(120)))
        }
        test("short timers get a wider neck so the same sand runs out sooner") {
            expect(near(P.neckScale(minutes: 25), 1), "25 minutes is the reference")
            expect(near(pow(P.neckScale(minutes: 10), 2.5), 2.5, 1e-9), "sand flows 2.5x faster through a 10-minute neck")
            expect(relNear(P.neckScale(minutes: 60), pow(25.0 / 60, 0.2)), "long timers narrow gently, using finer sand")
            expect(P.neckScale(minutes: 60) > 0.8, "a 60-minute stream doesn't look implausibly thin")
            expect(P.neckScale(minutes: 1) == 2.6 && P.neckScale(minutes: 1_000) == 0.6, "capped so it still looks like an hourglass")
            var last = Double.infinity
            for minutes in HourglassView.durations.map(Double.init) {
                expect(P.neckScale(minutes: minutes) <= last, "at \(minutes) min")
                last = P.neckScale(minutes: minutes)
            }
        }
        test("widening the neck changes only the pinch, not the bulbs") {
            expect(near(HourglassGeometry.outerRadius(0, neckScale: 2), HourglassGeometry.neckRadius * 2))
            expect(near(HourglassGeometry.outerRadius(HourglassGeometry.taperLength, neckScale: 2), HourglassGeometry.bulbRadius))
            expect(HourglassGeometry.innerRadius(0, neckScale: 2) > HourglassGeometry.innerRadius(0))
        }
        test("long timers keep a sturdy waist with thicker glass around a narrower bore") {
            let long = P.neckScale(minutes: 60)
            expect(near(HourglassGeometry.outerRadius(0, neckScale: long), HourglassGeometry.neckRadius), "the waist isn't thinned")
            let bore = HourglassGeometry.innerRadius(0, neckScale: long)
            expect(bore < HourglassGeometry.innerRadius(0), "the opening is narrower")
            expect(HourglassGeometry.outerRadius(0, neckScale: long) - bore > HourglassGeometry.wall + 0.2, "the glass is thicker at the pinch")
            expect(near(HourglassGeometry.innerRadius(40, neckScale: long), HourglassGeometry.innerRadius(40), 0.01), "normal glass away from the pinch")
        }
        test("volume and height convert back and forth") {
            for d in stride(from: 0.0, through: HourglassGeometry.halfLength, by: 7.3) {
                expect(near(geo.distance(forVolume: geo.volume(upTo: d)), d, 1e-3), "at \(d)")
            }
        }
        test("sand levels start full, end empty and only move one way") {
            expect(near(geo.topSandHeight(progress: 0), HourglassGeometry.sandFullHeight, 1e-3))
            expect(geo.topSandHeight(progress: 1) == 0)
            expect(near(geo.bottomSurfaceDistance(progress: 0), HourglassGeometry.halfLength, 1e-3))
            var lastTop = Double.infinity, lastBottom = Double.infinity
            for i in 0...20 {
                let p = Double(i) / 20
                let top = geo.topSandHeight(progress: p), bottom = geo.bottomSurfaceDistance(progress: p)
                expect(top <= lastTop && bottom <= lastBottom, "at \(p)")
                lastTop = top
                lastBottom = bottom
            }
            expect(geo.bottomSurfaceDistance(progress: 1) > HourglassGeometry.taperLength, "a full bottom stays in the straight part")
        }
    }

    suite("Sand shapes") {
        test("the bottom pile holds exactly the sand that has fallen") {
            for fraction in [0.001, 0.02, 0.2, 0.6, 1.0] {
                let v = geo.sandVolume * fraction
                expect(relNear(P.pileVolume(peak: P.pilePeak(volume: v)), v), "at \(fraction)")
            }
        }
        test("a small pile is a free-standing cone at the angle of repose") {
            let v = 2_000.0
            expect(relNear(P.pilePeak(volume: v), pow(3 * P.reposeSlope * P.reposeSlope * v / .pi, 1.0 / 3), 1e-2))
        }
        test("the pile grows steadily and stays below the neck") {
            var last = 0.0
            for i in 1...20 {
                let peak = P.pilePeak(volume: geo.sandVolume * Double(i) / 20)
                expect(peak > last)
                last = peak
            }
            expect(last < HourglassGeometry.halfLength)
        }
        test("the top crater leaves exactly the sand that remains") {
            let flat = geo.topSandHeight(progress: 0)
            let full = P.craterVolume(tip: flat, flatLevel: flat)
            expect(relNear(P.craterTip(volume: full, flatLevel: flat), flat), "no crater before any sand drains")
            for fraction in [0.97, 0.7, 0.3, 0.05] {
                let tip = P.craterTip(volume: full * fraction, flatLevel: flat)
                expect(relNear(P.craterVolume(tip: tip, flatLevel: flat), full * fraction), "at \(fraction)")
                expect(tip < flat, "has depth at \(fraction)")
            }
            let lastTip = P.craterTip(volume: full * 0.01, flatLevel: flat)
            expect(lastTip >= 0 && lastTip < HourglassGeometry.taperLength / 2, "the last sand sits low in the funnel")
        }
        test("sand landing on a leveled layer builds a cone on top instead of reshaping the layer") {
            let layer = P.bottomPile(progress: 0.5, settledProgress: 0.5)
            expect(layer.peak == 0 && near(layer.layer, HourglassGeometry.halfLength - geo.bottomSurfaceDistance(progress: 0.5), 1e-9),
                   "freshly settled sand is flat")
            var previousPeak = 0.0
            for progress in [0.505, 0.52, 0.55] {
                let pile = P.bottomPile(progress: progress, settledProgress: 0.5)
                expect(near(pile.layer, layer.layer, 1e-9), "the existing layer keeps its height at \(progress)")
                expect(near(pile.height(atRadius: 50), layer.layer, 1e-9), "the edges stay at the layer while the cone is small at \(progress)")
                expect(pile.peak > previousPeak, "the cone grows at \(progress)")
                previousPeak = pile.peak
            }
        }
        test("sand still in the air hasn't landed on the pile yet") {
            let duration = 60.0, inAir = P.flightTime / duration
            expect(P.flightTime > 0.3 && P.flightTime < 0.45, "about a third of a second from neck to pile")
            expect(near(P.landedProgress(progress: 0.5, settledProgress: 0.2, duration: duration, falling: true), 0.5 - inAir, 1e-12))
            expect(P.landedProgress(progress: 0.5, settledProgress: 0.5 - inAir / 2, duration: duration, falling: true) == 0.5 - inAir / 2,
                   "just after settling, nothing new has landed")
            expect(P.landedProgress(progress: 0.5, settledProgress: 0.2, duration: duration, falling: false) == 0.5,
                   "once nothing is falling, all the sand is down")
        }
        test("a layered pile holds exactly the sand in the bottom bulb") {
            for (progress, settled) in [(0.3, 0.0), (0.55, 0.5), (0.9, 0.4), (1.0, 0.7)] {
                let pile = P.bottomPile(progress: progress, settledProgress: settled)
                let radius = HourglassGeometry.innerRadius(HourglassGeometry.halfLength)
                // Volume of the solid of revolution under the surface, out to the straight bottom wall.
                var volume = 0.0
                let step = 0.05
                for rho in stride(from: step / 2, to: radius, by: step) { volume += 2 * .pi * rho * pile.height(atRadius: rho) * step }
                expect(relNear(volume, geo.sandVolume * progress, 0.01), "at \(progress) settled \(settled): \(volume) vs \(geo.sandVolume * progress)")
            }
        }
        test("heaps look natural: rounded peaks and feet, no hard corners, nearly the same sand") {
            let N = P.NaturalSurface.self
            expect(N.smoothMax(0, 5, width: 3) == 5 && N.smoothMax(2, 2, width: 4) > 2, "rounds only near the corner")
            expect(N.roundedCone(peak: 20, slope: 0.5, radius: 0, tipRadius: 5) == 20, "the tip keeps its height")
            expect(abs(N.roundedCone(peak: 20, slope: 0.5, radius: 30, tipRadius: 5) - (20 - 0.5 * 30)) < 0.5 * 5, "matches the cone away from the tip")
            let pile = P.bottomPile(progress: 0.55, settledProgress: 0.5)
            // Curvature: a hard corner shows up as a jump in slope between neighbouring points.
            var sharpest = 0.0, farthest = 0.0
            for x in stride(from: -50.0, through: 50.0, by: 0.5) {
                let bend = pile.naturalHeight(atOffset: x + 0.5, rough: false) - 2 * pile.naturalHeight(atOffset: x, rough: false) + pile.naturalHeight(atOffset: x - 0.5, rough: false)
                sharpest = max(sharpest, abs(bend))
                farthest = max(farthest, abs(pile.naturalHeight(atOffset: x) - pile.height(atRadius: abs(x))))
            }
            let corner = abs(pile.height(atRadius: pile.foot + 0.5) - 2 * pile.height(atRadius: pile.foot) + pile.height(atRadius: pile.foot - 0.5))
            expect(sharpest < corner * 0.5, "smoother than the ideal cone's corners: \(sharpest) vs \(corner)")
            expect(farthest < 3, "never more than a few units from the ideal shape: \(farthest)")
            let crater = P.topCrater(progress: 0.3, settledProgress: 0)
            expect(abs(crater.naturalHeight(atOffset: 0, rough: false) - max(0, crater.tip)) < 2.5, "the crater's bottom is rounded, not moved")
        }
        test("the top's crater starts fresh from wherever the sand last settled") {
            let fresh = P.topCrater(progress: 0.4, settledProgress: 0.4)
            expect(relNear(fresh.tip, fresh.level, 1e-3), "no crater right after settling")
            expect(near(fresh.level, geo.topSandHeight(progress: 0.4), 1e-9))
            let draining = P.topCrater(progress: 0.45, settledProgress: 0.4)
            expect(near(draining.level, fresh.level, 1e-9) && draining.tip < draining.level, "a crater forms in the settled surface")
            let old = P.topCrater(progress: 0.45, settledProgress: 0)
            expect(draining.level - draining.tip < old.level - old.tip, "shallower than one grown since the timer started")
        }
        test("the stream stays a steady thread, only faintly looser low down") {
            let top = P.streamSlice(at: 0), bottom = P.streamSlice(at: 1)
            expect(top.coreWidth == 1, "as wide as the opening at the neck")
            expect(bottom.coreWidth < top.coreWidth && bottom.coreOpacity < top.coreOpacity && bottom.spread > top.spread)
            var last = P.streamSlice(at: 0)
            for i in 1...10 {
                let slice = P.streamSlice(at: Double(i) / 10)
                expect(slice.coreWidth <= last.coreWidth && slice.coreOpacity <= last.coreOpacity && slice.spread >= last.spread)
                last = slice
            }
            expect(P.funnelLength(neckScale: 2.6) > P.funnelLength(neckScale: 1), "a wider opening converges over a longer distance")
            expect(bottom.coreWidth >= 0.85 && bottom.coreOpacity >= 0.8 && bottom.spread <= 0.3,
                   "no visible spray: dry sand falls as a thin, even thread")
        }
        test("sand pours with the square root of the gravity it feels, and not at all in free fall") {
            expect(P.flowRate(gravityFactor: 1) == 1)
            expect(P.flowRate(gravityFactor: 0) == 0 && P.flowRate(gravityFactor: -1) == 0)
            expect(near(P.flowRate(gravityFactor: 4), 2), "four times the gravity, twice the flow")
            expect(P.flowRate(gravityFactor: 0.5) < 1 && P.flowRate(gravityFactor: 1.5) > 1)
        }
        test("the stream falls under gravity") {
            expect(relNear(P.fallDistance(after: 0.25), 150))
            expect(P.fallDistance(after: -1) == 0)
        }
        test("falling sand sounds glassy at first and softer as the pile covers the glass") {
            expect(P.pourGlassiness(progress: 0) == 1)
            expect(P.pourGlassiness(progress: 0.05) < 0.5)
            expect(P.pourGlassiness(progress: 0.6) == 0)
            var last = 1.0
            for i in 0...40 {
                let g = P.pourGlassiness(progress: Double(i) / 40)
                expect(g <= last + 1e-12, "at \(Double(i) / 40)")
                last = g
            }
        }
    }

    suite("Sand while turning and lying down") {
        let square = [P.Point(x: 0, y: 0), P.Point(x: 10, y: 0), P.Point(x: 10, y: 10), P.Point(x: 0, y: 10)]
        test("polygon clipping and area") {
            expect(near(P.area(square), 100))
            expect(near(P.area(P.clip(square, gravity: P.Point(x: 0, y: 1), offset: 4)), 60))
            let diagonal = P.Point(x: sqrt(0.5), y: sqrt(0.5))
            expect(relNear(P.area(P.clip(square, gravity: diagonal, offset: P.surfaceOffset(square, gravity: diagonal, area: 37))), 37))
        }
        test("during a flip the sand moves from its old resting place to its new one") {
            expect(P.turningSand(angle: 0.3, progress: 0.4) == nil, "holds still early in the turn")
            for p in [0.0, 0.35, 1.0] {
                let startUpper = P.flatSandArea(upper: true, surfaceDistance: geo.topSandHeight(progress: p))
                let endUpper = P.flatSandArea(upper: false, surfaceDistance: geo.bottomSurfaceDistance(progress: 1 - p))
                if let begin = P.turningSand(angle: P.slideThreshold + 1e-6, progress: p) {
                    expect(relNear(P.area(begin.upper), startUpper, 1e-2), "start at \(p)")
                } else { expect(false, "sand exists after the threshold at \(p)") }
                guard let end = P.turningSand(angle: .pi, progress: p) else { expect(false, "sand at the end of the turn"); continue }
                expect(relNear(P.area(end.upper), endUpper, 1e-2), "end at \(p)")
                expect(end.upper.allSatisfy { $0.y <= P.neckY + 1e-6 }, "stays in its bulb at \(p)")
                if endUpper > 100 {
                    let meanY = end.upper.map(\.y).reduce(0, +) / Double(end.upper.count)
                    expect(meanY < P.neckY - HourglassGeometry.halfLength / 2, "upside down, the old top sand is at the cap end at \(p)")
                }
            }
            let mid = try require(P.turningSand(angle: .pi / 2, progress: 0.35), "sand mid-turn")
            expect(!mid.upper.isEmpty && !mid.lower.isEmpty, "both bulbs hold sand mid-turn")
        }
        test("lying on its side, each bulb keeps its sand along the lower wall") {
            expect(P.lyingSand(angle: 0.3, progress: 0.4) == nil)
            for p in [0.2, 0.7] {
                let lying = try require(P.lyingSand(angle: .pi / 2, progress: p), "lying sand at \(p)")
                let upperArea = P.flatSandArea(upper: true, surfaceDistance: geo.topSandHeight(progress: p))
                let lowerArea = P.flatSandArea(upper: false, surfaceDistance: geo.bottomSurfaceDistance(progress: p))
                expect(relNear(P.area(lying.upper), upperArea, 1e-2) && relNear(P.area(lying.lower), lowerArea, 1e-2))
                expect(lying.lower.map(\.x).reduce(0, +) / Double(lying.lower.count) > P.centerX + 10)
                expect(lying.upper.allSatisfy { $0.y <= P.neckY + 1e-6 } && lying.lower.allSatisfy { $0.y >= P.neckY - 1e-6 },
                       "no sand crosses the neck")
            }
            let left = try require(P.lyingSand(angle: -.pi / 2, progress: 0.3), "sand toppled left")
            expect(left.upper.map(\.x).reduce(0, +) / Double(left.upper.count) < P.centerX - 10, "toppled left, it lies on the other wall")
        }
        test("toppling pivots on the bottom corner, which stays on the ground") {
            let start = P.centerFromPivot(angle: 0, side: 1), end = P.centerFromPivot(angle: .pi / 2, side: 1)
            expect(near(start.x, -93) && near(start.y, 200))
            expect(near(end.x, 200) && near(end.y, 93))
            let left = P.centerFromPivot(angle: -.pi / 2, side: -1)
            expect(near(left.x, -200) && near(left.y, 93))
            for a in stride(from: 0.0, through: .pi / 2, by: 0.2) {
                expect(near(P.centerFromPivot(angle: a, side: 1).y, P.restingHalfHeight(angle: a), 1e-9), "at \(a)")
            }
        }
        test("the shadow is full on the ground and fades away as the timer is lifted") {
            expect(P.shadowStrength(heightAboveGround: 0) == 1 && P.shadowStrength(heightAboveGround: -5) == 1, "resting on the ground")
            expect(P.shadowStrength(heightAboveGround: 200) == 0, "no shadow when floating well above it")
            var last = 1.0
            for h in stride(from: 0.0, through: 100, by: 5) {
                expect(P.shadowStrength(heightAboveGround: h) <= last, "at \(h)")
                last = P.shadowStrength(heightAboveGround: h)
            }
        }
        test("the outline is the base discs' width standing and the full length lying down") {
            expect(near(P.restingHalfHeight(angle: 0), 200) && near(P.restingHalfHeight(angle: .pi / 2), 93))
            expect(near(P.restingHalfWidth(angle: 0), 93) && near(P.restingHalfWidth(angle: .pi / 2), 200))
        }
    }
}
