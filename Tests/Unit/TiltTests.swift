import Foundation

private typealias P = SandPhysics

func tiltTests() {
    suite("Tilting by hand") {
        test("it can lean about 25° on its base before it topples") {
            expect(near(P.tippingAngle * 180 / .pi, 24.94, 0.05), "\(P.tippingAngle * 180 / .pi)°")
        }
        test("pushing the top cap sideways leans it about the bottom corner on that side") {
            expect(P.tiltAngle(forTopShift: 0) == 0)
            expect(P.tiltAngle(forTopShift: 60) > 0 && P.tiltAngle(forTopShift: -60) < 0)
            expect(near(P.tiltAngle(forTopShift: 60), -P.tiltAngle(forTopShift: -60), 1e-12), "the same either way")
            var last = 0.0
            for shift in stride(from: 5.0, through: 300, by: 5) {
                let angle = P.tiltAngle(forTopShift: shift)
                expect(angle > last, "keeps leaning further at \(shift)")
                last = angle
            }
            // Pushed so the top cap's middle is directly above the pivot corner, it's leaning at exactly the tipping angle's
            // counterpart for the top: the cap has moved sideways by the base's half-width plus the lean.
            let atTip = P.tiltAngle(forTopShift: P.outlineHalfWidth + (P.outlineHalfWidth * P.outlineHalfWidth + 160_000).squareRoot() * sin(P.tippingAngle - atan2(P.outlineHalfWidth, 400)))
            expect(near(atTip, P.tippingAngle, 1e-9))
        }
        test("let go short of the tipping point, it rocks back upright and settles") {
            var motion = Rocking(angle: 0.3)
            var impacts: [Double] = [], time = 0.0
            while !motion.isSettled && time < 5 {
                motion.step(dt: 1.0 / 240)
                if let speed = motion.impactSpeed { impacts.append(speed) }
                time += 1.0 / 240
            }
            expect(motion.isSettled && motion.angle == 0, "settled upright")
            expect(time < 2, "within \(time) seconds")
            expect(!impacts.isEmpty && impacts.first! > 0.5, "lands on its base with a clack")
            expect(zip(impacts, impacts.dropFirst()).allSatisfy { $1 < $0 }, "each rebound lands softer")
            let over = Rocking(angle: P.tippingAngle + 0.01)
            expect(over.hasToppled, "past the tipping point it doesn't come back")
        }
        test("tilting makes the downhill side of a heap slump, keeping the uphill side and all the sand") {
            let spacing = 2.0
            let cone = (0...40).map { i -> Double in 20 - P.reposeSlope * abs(Double(i - 20) * spacing) }.map { max(0, $0) }
            let untouched = P.relaxSlopes(cone, spacing: spacing, tilt: 0, iterations: 50)
            expect(zip(cone, untouched).allSatisfy { abs($0 - $1) < 1e-9 }, "an upright heap at its natural slope stays as it is")
            let tilt = 0.2
            let slumped = P.relaxSlopes(cone, spacing: spacing, tilt: tilt, iterations: 400)
            expect(abs(slumped.reduce(0, +) - cone.reduce(0, +)) < 1e-6, "no sand gained or lost")
            let fallLimit = spacing * tan(tilt - atan(P.reposeSlope) - 0.02)
            let steepestFall = zip(slumped, slumped.dropFirst()).map { $1 - $0 }.min()!
            expect(steepestFall >= fallLimit - 0.05, "nothing downhill steeper than sand can hold: \(steepestFall) vs \(fallLimit)")
            expect(zip(cone.prefix(15), slumped.prefix(15)).allSatisfy { abs($0 - $1) < 1e-9 }, "the uphill side is left alone")
            expect(slumped[30] > cone[30], "sand has moved down the far side")
        }
        test("a toppled timer can be lifted back by its top cap, pointing toward the hand") {
            let upright = P.topCapFromPivot(angle: 0, side: 1)
            expect(near(upright.x, -P.outlineHalfWidth) && near(upright.y, 377), "standing, the top cap is above and inward of the corner")
            let lying = P.topCapFromPivot(angle: .pi / 2, side: 1)
            expect(near(lying.x, 377, 1e-9) && near(lying.y, P.outlineHalfWidth, 1e-9), "toppled right, it's out to the right, low down")
            expect(near(P.leanAngle(startingAt: .pi / 2, handSweep: 0.5, side: 1), .pi / 2 - 0.5), "sweeping the hand up lifts it")
            expect(P.leanAngle(startingAt: .pi / 2, handSweep: 3, side: 1) == 0, "it stops at upright")
            expect(P.leanAngle(startingAt: .pi / 2, handSweep: -1, side: 1) == .pi / 2, "and can't go below lying flat")
            expect(near(P.leanAngle(startingAt: -.pi / 2, handSweep: -0.5, side: -1), -.pi / 2 + 0.5), "the same on the other side")
        }
        test("slump changes are read back smoothly across the bulb") {
            var changes = [Double](repeating: 0, count: P.slumpColumns)
            changes[24] = 2
            expect(near(P.slump(changes, at: 0), 2))
            let halfway = P.slump(changes, at: P.slumpHalfWidth / Double(P.slumpColumns - 1))
            expect(near(halfway, 1, 1e-9), "halfway between columns: \(halfway)")
            expect(P.slump(changes, at: 100) == 0 && P.slump([], at: 0) == 0, "nothing outside the bulb or with no slump")
        }
    }
}
