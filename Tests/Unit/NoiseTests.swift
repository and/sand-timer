import Foundation

func noiseTests() {
    suite("Focus noise") {
        let rate = 44_100.0
        func rms(_ x: [Float]) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }
        /// How much of a signal is in its fast changes: high for a hiss, low for a rumble.
        func roughness(_ x: [Float]) -> Float { rms(zip(x.dropFirst(), x).map { $0 - $1 }) / rms(x) }

        test("each kind is evened out to its own loudness, and never clips") {
            for kind in NoiseKind.allCases {
                let loop = NoiseLoop.channel(kind, seconds: 3, crossfade: 0.5, sampleRate: rate, seed: 7)
                expect(abs(rms(loop) - kind.targetRMS) < kind.targetRMS * 0.03, "\(kind): \(rms(loop))")
                expect(loop.allSatisfy { abs($0) <= 1 }, "\(kind) stays within range")
                expect(loop.count == Int(3 * rate))
            }
        }
        test("white is a hiss, pink softer, brown a rumble") {
            let r = NoiseKind.allCases.map { roughness(NoiseLoop.channel($0, seconds: 2, crossfade: 0.5, sampleRate: rate, seed: 3)) }
            expect(r[0] > 1.2, "white changes fastest: \(r[0])")
            expect(r[0] > r[1] && r[1] > r[2], "each darker than the last: \(r)")
            expect(r[2] < r[1] / 2, "brown far darker than pink: \(r)")
        }
        test("the loop has no seam: going round from the end to the start is like any other step") {
            for kind in [NoiseKind.pink, .brown] {
                let loop = NoiseLoop.channel(kind, seconds: 2, crossfade: 0.5, sampleRate: rate, seed: 11)
                let steps = zip(loop.dropFirst(), loop).map { abs($0 - $1) }
                let seam = abs(loop[0] - loop[loop.count - 1])
                let typical = steps.sorted()[steps.count * 99 / 100]
                expect(seam <= typical, "\(kind): the seam (\(seam)) is no bigger than 99% of ordinary steps (\(typical))")
            }
        }
        test("left and right are different noise, so it sounds wide") {
            let left = NoiseLoop.channel(.pink, seconds: 2, crossfade: 0.5, sampleRate: rate, seed: 1)
            let right = NoiseLoop.channel(.pink, seconds: 2, crossfade: 0.5, sampleRate: rate, seed: 2)
            let correlation = zip(left, right).reduce(0) { $0 + $1.0 * $1.1 } / (rms(left) * rms(right) * Float(left.count))
            expect(abs(correlation) < 0.05, "uncorrelated: \(correlation)")
            expect(NoiseLoop.channel(.white, seconds: 0.1, crossfade: 0.05, sampleRate: rate, seed: 5)
                   == NoiseLoop.channel(.white, seconds: 0.1, crossfade: 0.05, sampleRate: rate, seed: 5), "and the same seed, the same noise")
        }
        test("volume is squared for fine control when quiet, and softness runs from untouched to muffled") {
            expect(NoiseLoop.gain(volume: 0) == 0 && NoiseLoop.gain(volume: 1) == 1 && NoiseLoop.gain(volume: 0.5) == 0.25)
            expect(NoiseLoop.gain(volume: 2) == 1 && NoiseLoop.gain(volume: -1) == 0, "kept within range")
            expect(abs(NoiseLoop.cutoff(softness: 0) - 20_000) < 1, "off: 20 kHz")
            expect(abs(NoiseLoop.cutoff(softness: 1) - 800) < 1, "full: about 800 Hz")
            expect(NoiseLoop.cutoff(softness: 0.5) < NoiseLoop.cutoff(softness: 0.25))
        }
    }
}
