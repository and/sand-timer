import AppKit

/// Synthesized sounds, so they feel like a physical timer rather than system alerts.
enum Sounds {
    /// Sand rustling against the glass while it turns, then a soft thud as the cap lands.
    static let flip: NSSound? = NSSound(data: wav(samples: synthesizeFlip(landingAt: 0.58)))

    /// A faint, seamless loop of grains pattering onto the pile.
    static let grains: NSSound? = {
        let sound = NSSound(data: wav(samples: synthesizeGrains(seconds: 4)))
        sound?.loops = true
        return sound
    }()

    private struct Noise {
        var seed: UInt32
        /// Uniform in -1...1.
        mutating func next() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 23) - 1
        }
        /// Uniform in 0...1.
        mutating func unit() -> Double { Double(next() + 1) / 2 }
    }

    static func synthesizeFlip(landingAt landing: Double, sampleRate: Double = 44_100) -> [Float] {
        let count = Int((landing + 0.35) * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var noise = Noise(seed: 0x1234_5678)

        var previous: Float = 0
        for i in 0..<count {
            let t = Double(i) / sampleRate

            // Rustle: high-passed noise with sparse grain clicks, swelling then fading before the landing.
            if t < landing {
                let envelope = Float(sin(.pi * t / landing)) * 0.07
                let white = noise.next()
                let hiss = white - previous
                previous = white
                let click: Float = noise.next() > 0.995 ? noise.next() * 0.6 : 0
                samples[i] += (hiss * 0.5 + click) * envelope
            }

            // Thud: a decaying low tone with a short noisy knock at the start.
            if t >= landing {
                let dt = t - landing
                let body = sin(2 * .pi * 95 * dt) * 0.55 + sin(2 * .pi * 190 * dt) * 0.18
                let knock = dt < 0.006 ? Double(noise.next()) * 0.35 * (1 - dt / 0.006) : 0
                samples[i] += Float((body * exp(-dt / 0.045)) + knock)
            }
        }
        return samples
    }

    static func synthesizeGrains(seconds: Double, sampleRate: Double = 44_100) -> [Float] {
        let count = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var noise = Noise(seed: 0x9ABC_DEF0)

        // A barely-there hiss underneath, so the ticks don't sound isolated.
        var previous: Float = 0
        for i in 0..<count {
            let white = noise.next()
            samples[i] = (white - previous) * 0.004
            previous = white
        }

        // Individual grains: tiny ticks with a slight glassy ring. Most are soft, a few land harder.
        // None cross the end of the buffer, so the loop has no audible seam.
        let length = Int(0.006 * sampleRate)
        for _ in 0..<Int(seconds * 80) {
            let start = Int(noise.unit() * Double(count - length))
            let amplitude = Float(pow(noise.unit(), 3)) * 0.1 + 0.008
            let ring = 2_500 + noise.unit() * 4_500
            for j in 0..<length {
                let dt = Double(j) / sampleRate
                let tone = Float(sin(2 * .pi * ring * dt)) * 0.4 + noise.next() * 0.6
                samples[start + j] += amplitude * Float(exp(-dt / 0.0009)) * tone
            }
        }
        return samples
    }

    /// 16-bit mono PCM WAV.
    static func wav(samples: [Float], sampleRate: Int = 44_100) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let payload = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + payload))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(payload))
        for s in samples { append(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}
