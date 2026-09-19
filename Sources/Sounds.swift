import AppKit

/// Synthesized sounds, so they feel like a physical timer rather than system alerts.
enum Sounds {
    /// Sand rustling against the glass while it turns, then a soft thud as the cap lands.
    static let flip: NSSound? = NSSound(data: wav(samples: synthesizeFlip(landingAt: 0.58)))

    /// Standing a paused timer back up: sand rustling back into place, then the base settling on the desk as the
    /// stand-up finishes (it takes `standUpDuration` seconds), a little softer than a flip.
    static func standUp(standUpDuration: Double) -> NSSound? {
        if standUpSound == nil {
            standUpSound = NSSound(data: wav(samples: synthesizeFlip(landingAt: standUpDuration - 0.02)))
            standUpSound?.volume = 0.75
        }
        return standUpSound
    }
    private static var standUpSound: NSSound?

    /// Falling sand, as two faint seamless loops blended by what the stream lands on: bare glass at first, then the
    /// growing pile. Both run together while sand falls; `setPour` sets the mix.
    static let pourOnGlass: NSSound? = looping(synthesizeGrains(seconds: 4))
    static let pourOnSand: NSSound? = looping(synthesizeSoftPour(seconds: 4))

    /// Starts, stops and mixes the falling-sand loops. `glassiness` is how much of the sound is grains hitting glass
    /// (1 = the bottom is bare) rather than sand landing on sand, which is softer.
    static func setPour(active: Bool, glassiness: Double, volume: Double = 1) {
        guard let glass = pourOnGlass, let sand = pourOnSand else { return }
        let levels = pourVolumes(glassiness: glassiness, volume: volume)
        guard active, levels.glass + levels.sand > 0 else {
            if glass.isPlaying { glass.stop() }
            if sand.isPlaying { sand.stop() }
            return
        }
        glass.volume = levels.glass
        sand.volume = levels.sand
        if !glass.isPlaying { glass.play() }
        if !sand.isPlaying { sand.play() }
    }

    /// How loud each falling-sand loop plays: the glass-and-sand mix, scaled by the chosen sand volume and kept
    /// within what a sound can play.
    static func pourVolumes(glassiness: Double, volume: Double) -> (glass: Float, sand: Float) {
        let level = max(0, volume)
        return (Float(min(1, glassiness * level)), Float(min(1, (1 - glassiness) * 0.7 * level)))
    }

    private static func looping(_ samples: [Float]) -> NSSound? {
        let sound = NSSound(data: wav(samples: samples))
        sound?.loops = true
        return sound
    }

    /// Sand being shaken about inside the glass, looped. Its volume is set from how stirred up the sand is.
    static let shake: NSSound? = {
        let sound = NSSound(data: wav(samples: synthesizeShake(seconds: 2)))
        sound?.loops = true
        sound?.volume = 0
        return sound
    }()

    /// The timer landing on a desk: a hollow plastic knock from the base, a faint rattle of the glass, and grains
    /// resettling inside.
    /// A soft, short bell tone for each minute that passes: quiet enough to notice without being startled.
    static let minuteChime: NSSound? = {
        let sound = NSSound(data: wav(samples: synthesizeMinuteChime()))
        sound?.volume = 0.5
        return sound
    }()

    static let fall: NSSound? = NSSound(data: wav(samples: synthesizeFall()))

    /// Impacts slower than this (m/s) are too gentle to hear.
    static let quietestFall = 0.15

    /// Plays the landing sound, louder for harder impacts. Each landing gets its own copy so quick bounces can overlap.
    static func playFall(impactSpeed: Double) {
        guard let volume = fallVolume(impactSpeed: impactSpeed), let sound = fall?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    /// Volume for a landing at `impactSpeed` (m/s), or nil if it's too gentle to hear.
    static func fallVolume(impactSpeed: Double) -> Float? {
        impactSpeed >= quietestFall ? Float(min(1, 0.12 + impactSpeed / 2.5)) : nil
    }

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

    static func synthesizeMinuteChime(sampleRate: Double = 44_100) -> [Float] {
        let count = Int(1.2 * sampleRate)
        return (0..<count).map { i in
            let t = Double(i) / sampleRate
            // A struck small bell: a pure fundamental with a few quieter, faster-fading partials and a soft attack.
            let attack = min(1, t / 0.004, (1.2 - t) / 0.1)
            let tone = sin(2 * .pi * 880 * t) * exp(-t / 0.35)
                + sin(2 * .pi * 1760 * t) * 0.25 * exp(-t / 0.18)
                + sin(2 * .pi * 2640 * t) * 0.08 * exp(-t / 0.08)
            return Float(tone * attack * 0.25)
        }
    }

    static func synthesizeFall(sampleRate: Double = 44_100) -> [Float] {
        let count = Int(0.5 * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var noise = Noise(seed: 0x51F0_A11D)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            // Knock: a noisy strike, then the hollow plastic base and the desk ringing briefly.
            let strike = t < 0.004 ? Double(noise.next()) * 0.5 * (1 - t / 0.004) : 0
            let base = sin(2 * .pi * 170 * t) * 0.5 * exp(-t / 0.035) + sin(2 * .pi * 540 * t) * 0.22 * exp(-t / 0.014)
            let desk = sin(2 * .pi * 78 * t) * 0.3 * exp(-t / 0.06)
            let click = sin(2 * .pi * 1_250 * t) * 0.12 * exp(-t / 0.006)
            // Glass: a faint high rattle as the bulbs shake in the frame.
            let glass = (sin(2 * .pi * 3_150 * t) + sin(2 * .pi * 4_730 * t) * 0.7) * 0.03 * exp(-t / 0.045)
            samples[i] = Float(strike + base + desk + click + glass) * 0.85
        }
        // Grains resettling: a spray of tiny ticks that thins out over a quarter second.
        let tick = Int(0.005 * sampleRate)
        for _ in 0..<70 {
            let delay = pow(noise.unit(), 2) * 0.28
            let start = Int((0.01 + delay) * sampleRate)
            guard start + tick < count else { continue }
            let amplitude = Float(0.05 * (1 - delay / 0.3) * (0.3 + noise.unit()))
            for j in 0..<tick {
                samples[start + j] += amplitude * Float(exp(-Double(j) / sampleRate / 0.0009)) * noise.next()
            }
        }
        return samples
    }

    /// Fine sand pouring onto a heap inside a glass vessel. Thousands of grains land every second, so none stands out,
    /// and each is a hard, very short tick; the glass around them rings faintly at its own fixed notes. No soft rustle
    /// underneath (that sounds like paper), and no per-grain pitch (that sounds like dripping water).
    static func synthesizeGrains(seconds: Double, sampleRate: Double = 44_100) -> [Float] {
        let count = Int(seconds * sampleRate)
        var noise = Noise(seed: 0x9ABC_DEF0)
        var raw = [Float](repeating: 0, count: count)
        let click = Int(0.001 * sampleRate)
        // Many evenly soft grains rather than fewer uneven ones, so no single tick pops out.
        for _ in 0..<Int(seconds * 2_400) {
            addClick(to: &raw, at: Int(noise.unit() * Double(count)), length: click, amplitude: Float(0.8 + 0.4 * noise.unit()),
                     decay: 0.00008 + 0.00012 * noise.unit(), sampleRate: sampleRate, noise: &noise)
        }
        for i in 0..<count { raw[i] += noise.next() * 0.08 }

        var sound = glassy(bandLimitedLoop(raw, highPass: 1_200, lowPass: 12_000, sampleRate: sampleRate), ring: 0.12, sampleRate: sampleRate)
        // The stream's level wavers a little. Both cycles fit the loop a whole number of times, so it repeats seamlessly.
        let slow = 2 * Double.pi / seconds
        for i in 0..<count {
            let t = Double(i) / sampleRate
            sound[i] *= Float(1 + 0.18 * sin(slow * 2 * t) + 0.1 * sin(slow * 7 * t + 1.3))
        }
        return normalized(sound, rms: 0.006)
    }

    /// Sand landing on sand: the same dense, unpitched grains, but each impact is cushioned, so the ticks are softer and
    /// duller and there's no glass ring, just a gentle hush.
    static func synthesizeSoftPour(seconds: Double, sampleRate: Double = 44_100) -> [Float] {
        let count = Int(seconds * sampleRate)
        var noise = Noise(seed: 0x50F7_5A2D)
        var raw = [Float](repeating: 0, count: count)
        let click = Int(0.003 * sampleRate)
        for _ in 0..<Int(seconds * 2_400) {
            addClick(to: &raw, at: Int(noise.unit() * Double(count)), length: click, amplitude: Float(0.8 + 0.4 * noise.unit()),
                     decay: 0.0003 + 0.0003 * noise.unit(), sampleRate: sampleRate, noise: &noise)
        }
        for i in 0..<count { raw[i] += noise.next() * 0.2 }
        var sound = bandLimitedLoop(raw, highPass: 400, lowPass: 4_500, sampleRate: sampleRate)
        let slow = 2 * Double.pi / seconds
        for i in 0..<count {
            let t = Double(i) / sampleRate
            sound[i] *= Float(1 + 0.18 * sin(slow * 2 * t + 0.7) + 0.1 * sin(slow * 5 * t))
        }
        return normalized(sound, rms: 0.006)
    }

    /// Sand thrown about inside a glass vessel: clumps of grains strike the glass together in sharp little bursts,
    /// loose grains tick in between, and the glass rings faintly at its own notes. Unpitched grains, no papery rustle.
    static func synthesizeShake(seconds: Double, sampleRate: Double = 44_100) -> [Float] {
        let count = Int(seconds * sampleRate)
        var noise = Noise(seed: 0x5A4D_5EED)
        var raw = [Float](repeating: 0, count: count)
        let click = Int(0.001 * sampleRate)
        for _ in 0..<Int(seconds * 40) {
            let center = noise.unit() * Double(count)
            for _ in 0..<Int(20 + 40 * noise.unit()) {
                let start = Int(center + (noise.unit() - 0.5) * 0.016 * sampleRate + Double(count)) % count
                addClick(to: &raw, at: start, length: click, amplitude: Float(0.5 + noise.unit()),
                         decay: 0.00006 + 0.00008 * noise.unit(), sampleRate: sampleRate, noise: &noise)
            }
        }
        for _ in 0..<Int(seconds * 800) {
            addClick(to: &raw, at: Int(noise.unit() * Double(count)), length: click, amplitude: Float(0.2 + 0.3 * noise.unit()),
                     decay: 0.0001, sampleRate: sampleRate, noise: &noise)
        }
        let sound = glassy(bandLimitedLoop(raw, highPass: 1_500, lowPass: 13_000, sampleRate: sampleRate), ring: 0.18, sampleRate: sampleRate)
        return normalized(sound, rms: 0.03)
    }

    // MARK: Building blocks

    /// Adds one grain: a noise burst dying away in `decay` seconds, wrapping around the end so loops have no seam.
    private static func addClick(to buffer: inout [Float], at start: Int, length: Int, amplitude: Float, decay: Double,
                                 sampleRate: Double, noise: inout Noise) {
        for j in 0..<length {
            buffer[(start + j) % buffer.count] += amplitude * Float(exp(-Double(j) / sampleRate / decay)) * noise.next()
        }
    }

    /// High- and low-pass filtered, run over the loop twice so the filters' state wraps around and the seam stays clean.
    private static func bandLimitedLoop(_ raw: [Float], highPass: Double, lowPass: Double, sampleRate: Double) -> [Float] {
        let high = Float(exp(-2 * Double.pi * highPass / sampleRate))
        let low = Float(exp(-2 * Double.pi * lowPass / sampleRate))
        var out = [Float](repeating: 0, count: raw.count)
        var previousIn: Float = 0, highOut: Float = 0, lowOut: Float = 0
        for pass in 0..<2 {
            for i in raw.indices {
                highOut = high * (highOut + raw[i] - previousIn)
                previousIn = raw[i]
                lowOut = (1 - low) * highOut + low * lowOut
                if pass == 1 { out[i] = lowOut }
            }
        }
        return out
    }

    /// Mixes in the ring of a small glass vessel: the same few resonant notes, excited by every hit and dying within a
    /// few hundredths of a second. `ring` is how much of the result is the glass.
    private static func glassy(_ dry: [Float], ring: Float, sampleRate: Double) -> [Float] {
        let modes: [(frequency: Double, decay: Double)] = [(2_350, 0.014), (3_900, 0.010), (6_100, 0.007)]
        var wet = [Float](repeating: 0, count: dry.count)
        for mode in modes {
            let r = exp(-1 / (mode.decay * sampleRate))
            let a1 = Float(2 * r * cos(2 * Double.pi * mode.frequency / sampleRate)), a2 = Float(-r * r)
            var y1: Float = 0, y2: Float = 0
            var resonance = [Float](repeating: 0, count: dry.count)
            for pass in 0..<2 {  // twice round the loop, so the ringing carries over the seam
                for i in dry.indices {
                    let y = dry[i] + a1 * y1 + a2 * y2
                    y2 = y1
                    y1 = y
                    if pass == 1 { resonance[i] = y }
                }
            }
            let scale = rms(dry) / max(rms(resonance), 1e-9) / Float(modes.count)
            for i in wet.indices { wet[i] += resonance[i] * scale }
        }
        return dry.indices.map { dry[$0] * (1 - ring) + wet[$0] * ring }
    }

    private static func rms(_ x: [Float]) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))).squareRoot() }

    private static func normalized(_ x: [Float], rms target: Float) -> [Float] {
        let level = rms(x)
        return level > 0 ? x.map { $0 * target / level } : x
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
