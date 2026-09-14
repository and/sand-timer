import Foundation

private typealias P = SandPhysics

func motionTests() {
    suite("Screen box") {
        let box = (minX: 0.0, maxX: 1440.0, minY: 0.0, maxY: 870.0)
        test("free to move inside") {
            let inside = P.keptInside(x: 700, y: 400, halfWidth: 100, halfHeight: 200, box: box)
            expect(inside.x == 700 && inside.y == 400)
        }
        test("stops at each wall, the floor and the ceiling") {
            let pushed = P.keptInside(x: 1500, y: -50, halfWidth: 100, halfHeight: 200, box: box)
            expect(pushed.x == 1340 && pushed.y == 200)
            let ceiling = P.keptInside(x: 20, y: 900, halfWidth: 100, halfHeight: 200, box: box)
            expect(ceiling.x == 100 && ceiling.y == 670)
        }
        test("an outline bigger than the box is centered in it") {
            let squeezed = P.keptInside(x: 0, y: 0, halfWidth: 1000, halfHeight: 200, box: box)
            expect(squeezed.x == 720)
        }
    }

    suite("Gravity") {
        test("a raised timer falls, bounces a little and settles on the floor") {
            var drop = Drop(y: 700, floor: 50)
            expect(!drop.isResting)
            var lowest = drop.y, bounced = false, steps = 0
            while !drop.isResting && steps < 600 {
                drop.step(dt: 1.0 / 60)
                lowest = min(lowest, drop.y)
                if drop.velocity > 0 { bounced = true }
                steps += 1
            }
            expect(drop.isResting && drop.y == 50)
            expect(lowest >= 50, "never sinks below the floor")
            expect(bounced)
            expect(Double(steps) / 60 < 1.5, "settles quickly")
        }
        test("landing speed matches the drop height and each bounce is softer") {
            var drop = Drop(y: 650, floor: 50)
            var impacts: [Double] = []
            while !drop.isResting { drop.step(dt: 1.0 / 240); if let v = drop.impactSpeed { impacts.append(v) } }
            expect(relNear(impacts.first ?? 0, (2 * Drop.gravity * 600).squareRoot(), 0.02))
            expect(impacts.count >= 2 && impacts[1] < impacts[0] * 0.5)
        }
        test("let go below the floor, it just sits on the floor") {
            let drop = Drop(y: 20, floor: 50)
            expect(drop.isResting && drop.y == 50)
        }
    }

    suite("Stream bend") {
        test("sideways acceleration bends the stream by the tilt of apparent gravity") {
            var lean = StreamLean()
            for _ in 0..<60 { lean.step(acceleration: 3_000, timerHeightPoints: 300, dt: 1.0 / 60) }
            expect(lean.angle < 0, "trails behind the movement")
            expect(near(lean.angle, -atan(3_000 * P.timerHeightMeters / 300 / P.earthGravity), 1e-3))
        }
        test("the bend is limited and straightens once movement stops") {
            var lean = StreamLean()
            for _ in 0..<60 { lean.step(acceleration: 1_000_000, timerHeightPoints: 300, dt: 1.0 / 60) }
            expect(abs(lean.angle) <= StreamLean.maxAngle)
            for _ in 0..<120 { lean.step(acceleration: 0, timerHeightPoints: 300, dt: 1.0 / 60) }
            expect(lean.isSettled)
        }
    }

    suite("Shaking and jolts") {
        test("gentle moves leave the heaps alone; hard shakes stir them") {
            var sand = Agitation()
            sand.shake(acceleration: 3)
            expect(sand.isSettled)
            sand.shake(acceleration: 15)
            expect(sand.level > 0 && sand.level < 1)
            for _ in 0..<180 { sand.step(dt: 1.0 / 60) }
            expect(sand.isSettled, "grains settle once the shaking stops")
        }
        test("a higher drop jolts the sand harder, up to a limit") {
            let metersPerPoint = P.timerHeightMeters / 300
            func level(fromHeight points: Double) -> Double {
                var sand = Agitation()
                sand.impact(speed: Agitation.impactSpeed(windowSpeed: (2 * Drop.gravity * points).squareRoot(), metersPerPoint: metersPerPoint))
                return sand.level
            }
            expect(relNear(Agitation.impactSpeed(windowSpeed: (2 * Drop.gravity * 400).squareRoot(), metersPerPoint: metersPerPoint),
                           (2 * P.earthGravity * 400 * metersPerPoint).squareRoot()), "same as a real fall from that height")
            expect(level(fromHeight: 20) < level(fromHeight: 200) && level(fromHeight: 200) < level(fromHeight: 800))
            expect(level(fromHeight: 5_000) == 1)
        }
    }
}
