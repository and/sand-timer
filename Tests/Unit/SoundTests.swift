import AppKit
import Accelerate

/// Sounds are made in code, so their character can be checked by measuring the samples.
func soundTests() {
    let rate = 44_100.0
    let pourOnGlass = Sounds.synthesizeGrains(seconds: 4)
    let pourOnSand = Sounds.synthesizeSoftPour(seconds: 4)
    let shake = Sounds.synthesizeShake(seconds: 2)
    let fall = Sounds.synthesizeFall()
    let flip = Sounds.synthesizeFlip(landingAt: 0.58)
    let chime = Sounds.synthesizeMinuteChime()
    let all: [(String, [Float])] = [("pour on glass", pourOnGlass), ("pour on sand", pourOnSand), ("shake", shake), ("fall", fall), ("flip", flip),
                                    ("minute chime", chime)]

    suite("Sounds") {
        test("every sound is audible and never distorts") {
            for (name, samples) in all {
                expect(!samples.isEmpty, name)
                expect(samples.map(abs).max() ?? 0 <= 1, "\(name) clips")
                expect(rms(samples) > 0.001, "\(name) is silent")
            }
        }
        test("sounds last as long as they should") {
            expect(near(Double(pourOnGlass.count) / rate, 4, 0.01) && near(Double(shake.count) / rate, 2, 0.01))
            expect(near(Double(fall.count) / rate, 0.5, 0.01))
            expect(near(Double(flip.count) / rate, 0.93, 0.01), "the flip thud lands as the turn ends")
        }
        test("the minute chime is gentle: quieter than a fall, and fades out to silence") {
            expect(rms(chime) < rms(fall), "chime \(rms(chime)) vs fall \(rms(fall))")
            expect(abs(chime.first ?? 1) < 0.01 && chime.suffix(441).map(abs).max() ?? 1 < 0.01, "no click at either end")
        }
        test("looping sounds repeat without an audible seam") {
            for (name, loop) in [("pour on glass", pourOnGlass), ("pour on sand", pourOnSand), ("shake", shake)] {
                // The jump from the last sample back to the first should be no bigger than normal sample-to-sample steps.
                let steps = zip(loop, loop.dropFirst()).map { abs($1 - $0) }.sorted()
                expect(abs(loop[0] - loop[loop.count - 1]) <= steps[Int(Double(steps.count) * 0.99)], name)
            }
        }
        test("sand sounds are unpitched, so they don't sound like dripping water") {
            for (name, loop, minimum) in [("pour on glass", pourOnGlass, 0.5), ("shake", shake, 0.5), ("pour on sand", pourOnSand, 0.38)] {
                let flatness = medianFlatnessAtPeaks(loop, rate: rate)
                expect(flatness >= minimum, String(format: "%@ flatness %.2f", name, flatness))
            }
        }
        test("falling sand is a steady texture, not separate drips") {
            expect(audibleHitsPerSecond(pourOnGlass, rate: rate) <= 20, "on glass")
            expect(audibleHitsPerSecond(pourOnSand, rate: rate) <= 5, "on sand")
        }
        test("sand on sand is duller than sand on glass") {
            expect(highFrequencyShare(pourOnSand, rate: rate) < highFrequencyShare(pourOnGlass, rate: rate) - 0.15)
        }
        test("falls are louder the harder they land, and gentle taps are silent") {
            expect(Sounds.fallVolume(impactSpeed: 0.1) == nil)
            let soft = try require(Sounds.fallVolume(impactSpeed: 0.3), "soft landing")
            let hard = try require(Sounds.fallVolume(impactSpeed: 2), "hard landing")
            expect(soft < hard && hard <= 1)
            expect(Sounds.fallVolume(impactSpeed: 50) == 1)
        }
        test("sounds are valid WAV data that macOS can load") {
            let data = Sounds.wav(samples: fall)
            expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
            expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
            expect(data.count == 44 + fall.count * 2)
            expect(NSSound(data: data) != nil)
            expect(Sounds.pourOnGlass?.loops == true && Sounds.pourOnSand?.loops == true && Sounds.shake?.loops == true)
            expect(Sounds.standUp(standUpDuration: 0.7) != nil && Sounds.flip != nil && Sounds.fall != nil)
        }
    }
}

private func rms(_ x: [Float]) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot() }

private func powerSpectrum(_ x: [Float], from start: Int, size n: Int) -> [Float] {
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    var segment = Array(x[start..<start + n])
    vDSP_vmul(segment, 1, window, 1, &segment, 1, vDSP_Length(n))
    let log2n = vDSP_Length(log2(Float(n)))
    let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    var real = [Float](repeating: 0, count: n / 2), imaginary = [Float](repeating: 0, count: n / 2)
    var power = [Float](repeating: 0, count: n / 2)
    real.withUnsafeMutableBufferPointer { r in
        imaginary.withUnsafeMutableBufferPointer { i in
            var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
            segment.withUnsafeBufferPointer {
                $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
        }
    }
    return power
}

/// Spectral flatness around the loudest moment of each 50 ms: about 0.57 for plain noise, lower for pitched sounds.
private func medianFlatnessAtPeaks(_ x: [Float], rate: Double) -> Double {
    let block = Int(rate * 0.05), size = 256
    var values: [Double] = []
    for start in stride(from: 0, to: x.count - block - size, by: block) {
        let slice = x[start..<start + block].map(abs)
        let peak = start + (slice.firstIndex(of: slice.max()!) ?? 0)
        let from = max(0, min(x.count - size, peak - 64))
        let power = powerSpectrum(x, from: from, size: size).dropFirst(3).map { Double($0) + 1e-15 }
        values.append(exp(power.map(log).reduce(0, +) / Double(power.count)) / (power.reduce(0, +) / Double(power.count)))
    }
    return values.sorted()[values.count / 2]
}

/// How many 10 ms windows a second contain a peak standing well clear of the texture (over 6x its RMS).
private func audibleHitsPerSecond(_ x: [Float], rate: Double) -> Double {
    let window = Int(rate / 100), level = rms(x)
    var hits = 0
    for start in stride(from: 0, to: x.count - window, by: window) where x[start..<start + window].map(abs).max()! > 6 * level {
        hits += 1
    }
    return Double(hits) / (Double(x.count) / rate)
}

/// Share of energy above 7 kHz.
private func highFrequencyShare(_ x: [Float], rate: Double) -> Double {
    let size = 1024
    var total = [Float](repeating: 0, count: size / 2)
    for start in stride(from: 0, to: x.count - size, by: size / 2) {
        let power = powerSpectrum(x, from: start, size: size)
        vDSP_vadd(total, 1, power, 1, &total, 1, vDSP_Length(size / 2))
    }
    let cutoff = Int(7_000 / (rate / Double(size)))
    return Double(total[cutoff...].reduce(0, +) / total.reduce(0, +))
}
