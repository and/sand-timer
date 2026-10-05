import AVFoundation

/// A steady background noise to work to while the sand runs: white, pink or brown, made here rather than shipped as
/// recordings. White is a hiss with equal energy at every pitch, pink falls away gently toward the highs (like rain),
/// brown steeply (a low rumble).
enum NoiseKind: String, CaseIterable {
    case white, pink, brown

    /// What the menu calls it, with a word for how it sounds.
    var title: String { ["White Noise (hiss)", "Pink Noise (rain)", "Brown Noise (rumble)"][Self.allCases.firstIndex(of: self)!] }
    /// Loudness each is evened out to, so switching doesn't jump: white needs least, since the ear weights its highs.
    var targetRMS: Float { [0.10, 0.16, 0.22][Self.allCases.firstIndex(of: self)!] }
}

/// The three generators, sample by sample, from uniform white noise. Kept apart from any audio so they can be tested.
struct NoiseGenerator {
    let kind: NoiseKind
    private var rng: SplitMix
    private var b = [Double](repeating: 0, count: 7)
    private var last = 0.0

    init(kind: NoiseKind, seed: UInt64) {
        self.kind = kind
        rng = SplitMix(seed)
        for _ in 0..<3000 { _ = next() }  // let the filters settle before anything is heard
    }

    mutating func next() -> Float {
        let w = rng.unit() * 2 - 1
        switch kind {
        case .white:
            return Float(w)
        case .pink:
            // Paul Kellet's filter: -3 dB an octave.
            b[0] = 0.99886 * b[0] + w * 0.0555179
            b[1] = 0.99332 * b[1] + w * 0.0750759
            b[2] = 0.96900 * b[2] + w * 0.1538520
            b[3] = 0.86650 * b[3] + w * 0.3104856
            b[4] = 0.55000 * b[4] + w * 0.5329522
            b[5] = -0.7616 * b[5] - w * 0.0168980
            let out = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + w * 0.5362
            b[6] = w * 0.115926
            return Float(out)
        case .brown:
            // A leaky running sum: -6 dB an octave, without the drift a plain sum would wander off with.
            last = (last + 0.02 * w) / 1.02
            return Float(last * 3.5)
        }
    }
}

/// What plays while the sand runs: nothing, the falling sand itself, or one of the noises. One at a time — two
/// steady sounds on top of each other is just more hiss — with one volume for whichever it is.
enum Background: String, CaseIterable {
    case silence, sand, white, pink, brown

    var title: String {
        switch self {
        case .silence: return "Silence"
        case .sand: return "Falling Sand"
        default: return noise?.title ?? ""
        }
    }

    /// The noise this is, if it is one.
    var noise: NoiseKind? { NoiseKind(rawValue: rawValue) }
}

/// A small, fast random source that can be seeded, so a test hears the same noise every time.
struct SplitMix {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

enum NoiseLoop {
    /// One channel of a seamless loop: `seconds` long, its last second crossfaded into its first with equal power, so
    /// that playing it round and round has no seam to hear. Evened out to the kind's loudness, and kept within range.
    static func channel(_ kind: NoiseKind, seconds: Double = 12, crossfade: Double = 1, sampleRate: Double, seed: UInt64) -> [Float] {
        let n = Int(seconds * sampleRate), f = Int(crossfade * sampleRate)
        var generator = NoiseGenerator(kind: kind, seed: seed)
        let raw = (0..<(n + f)).map { _ in generator.next() }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if i < f {
                let t = Float(i) / Float(f) * .pi / 2
                out[i] = raw[i] * sin(t) + raw[n + i] * cos(t)
            } else {
                out[i] = raw[i]
            }
        }
        let rms = (out.reduce(0) { $0 + $1 * $1 } / Float(max(1, n))).squareRoot()
        let gain = rms > 0 ? kind.targetRMS / rms : 0
        return out.map { min(1, max(-1, $0 * gain)) }
    }

    /// Volume as the slider reads (0 to 1) to gain: squared, for finer control at the quiet end, where people listen.
    static func gain(volume: Double) -> Float { Float(min(1, max(0, volume)) * min(1, max(0, volume))) }

    /// Softness (0 to 1) to a low-pass cutoff: 20 kHz, which leaves the sound as it is, down to about 800 Hz, evenly to
    /// the ear on the way.
    static func cutoff(softness: Double) -> Float { Float(20_000 * pow(0.04, min(1, max(0, softness)))) }
}

/// Plays the focus noise. One kind at a time; changing kind crossfades, and starting and stopping fade, so nothing
/// clicks. The audio engine is started only when there is something to play and stopped once it has faded out.
final class FocusNoise {
    static let shared = FocusNoise()
    static let backgroundKey = "backgroundSound"
    static let volumeKey = "soundVolume"
    static let softnessKey = "focusNoiseSoftness"
    static let defaultVolume = 0.35

    /// What plays while the sand runs. Remembered.
    private(set) var background = FocusNoise.startingBackground()
    /// How loud it is, 0 to 1, whichever it is. Remembered.
    private(set) var volume = FocusNoise.startingVolume()
    private(set) var softness = UserDefaults.standard.double(forKey: FocusNoise.softnessKey)

    /// The noise playing while the sand runs, if the background is a noise.
    var kind: NoiseKind? { background.noise }

    /// How loud the falling sand is, as the pouring sound takes it (1 its usual level, up to 2), or 0 when the
    /// background is something else. Half way up the volume is the usual level.
    var sandLoudness: Double { background == .sand ? 2 * volume : 0 }

    /// The background chosen last time. Before there was one choice there were two settings — a volume for the sand,
    /// and briefly a noise — and whichever of those was on carries over. A fresh install starts in silence.
    static func startingBackground(_ defaults: UserDefaults = .standard) -> Background {
        if let chosen = defaults.string(forKey: backgroundKey).flatMap(Background.init) { return chosen }
        if let noise = defaults.string(forKey: "focusNoise").flatMap(Background.init) { return noise }
        return legacySandVolume(defaults) > 0 ? .sand : .silence
    }

    /// The volume chosen last time; for someone coming from the sand's own volume, the same loudness on the new scale.
    static func startingVolume(_ defaults: UserDefaults = .standard) -> Double {
        if let chosen = defaults.object(forKey: volumeKey) as? Double { return chosen }
        // A noise carried over keeps the volume it played at; the sand's volume is only for the sand.
        if defaults.string(forKey: "focusNoise").flatMap(Background.init) != nil {
            return defaults.object(forKey: "focusNoiseVolume") as? Double ?? defaultVolume
        }
        let sand = legacySandVolume(defaults)
        return sand > 0 ? min(1, sand / 2) : defaultVolume
    }

    /// The falling sand's own volume, from before the sounds were one choice: Quiet 0.45, Normal 1, Loud 1.8, Off 0
    /// — or, older still, a plain on or off.
    static func legacySandVolume(_ defaults: UserDefaults) -> Double {
        if let chosen = defaults.object(forKey: "grainVolume") as? Double { return chosen }
        return defaults.object(forKey: "grainSoundOn") as? Bool == true ? 1 : 0
    }

    /// Whether the noise should be heard now: the timer says so while its sand runs.
    private var wanted = false
    /// A short taste of a kind just picked while the timer is still, until this moment.
    private var previewUntil: Date?
    /// What is sounding, or fading: each voice's player, how loud it is now, and how loud it is heading for.
    private final class Voice {
        let kind: NoiseKind
        let player = AVAudioPlayerNode()
        var level: Float = 0
        var target: Float = 1
        var rate: Float
        init(kind: NoiseKind, rate: Float) { self.kind = kind; self.rate = rate }
    }
    private var voices: [Voice] = []
    private var engine: AVAudioEngine?
    private let mixer = AVAudioMixerNode()
    private let lowPass = AVAudioUnitEQ(numberOfBands: 1)
    private var buffers: [NoiseKind: AVAudioPCMBuffer] = [:]
    private var master: Float = 0
    private var cutoff: Float = 20_000
    private var ramp: Timer?
    private static let fadeIn: Float = 0.6, crossFade: Float = 0.6, fadeOut: Float = 0.5
    private static let step = 0.01

    /// Whether any noise is sounding: tests listen here.
    var isPlaying: Bool { voices.contains { $0.target > 0 } }
    /// The kind sounding now, once any crossfade has settled: tests look here.
    var playingKind: NoiseKind? { voices.last { $0.target > 0 }?.kind }

    func choose(_ newBackground: Background) {
        background = newBackground
        UserDefaults.standard.set(newBackground.rawValue, forKey: Self.backgroundKey)
        // A noise picked while the sand is still: a few seconds of it, so the choice can be heard. (The falling sand
        // is heard as soon as there is sand falling.)
        previewUntil = !wanted && newBackground.noise != nil ? Date().addingTimeInterval(2.5) : nil
        update()
    }

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        UserDefaults.standard.set(volume, forKey: Self.volumeKey)
        startRamping()
    }

    func setSoftness(_ value: Double) {
        softness = min(1, max(0, value))
        UserDefaults.standard.set(softness, forKey: Self.softnessKey)
        startRamping()
    }

    /// Told by the timer, as often as it likes: whether its sand is running. Only a change does anything.
    func setSessionRunning(_ running: Bool) {
        guard running != wanted else { return }
        wanted = running
        if running { previewUntil = nil }
        update()
    }

    /// Stops at once, with no fade: for tests, so one test's noise never carries into the next.
    func silence() {
        wanted = false
        previewUntil = nil
        voices.forEach { $0.player.stop() }
        voices.removeAll()
        stopEngine()
    }

    /// Brings what's sounding in line with what should be.
    private func update() {
        let audible = kind != nil && (wanted || (previewUntil.map { $0 > Date() } ?? false))
        if audible, let kind {
            if voices.last?.kind == kind, voices.last?.target == 1 { return }
            guard let voice = makeVoice(kind) else { return }
            let switching = voices.contains { $0.target > 0 }
            for old in voices { old.target = 0; old.rate = 1 / Self.crossFade }
            voice.rate = 1 / (switching ? Self.crossFade : Self.fadeIn)
            voices.append(voice)
        } else {
            for voice in voices { voice.target = 0; voice.rate = 1 / Self.fadeOut }
        }
        startRamping()
    }

    private func makeVoice(_ kind: NoiseKind) -> Voice? {
        guard let engine = startEngine(), let buffer = buffer(kind, rate: engine.outputNode.outputFormat(forBus: 0).sampleRate) else { return nil }
        let voice = Voice(kind: kind, rate: 1 / Self.fadeIn)
        engine.attach(voice.player)
        engine.connect(voice.player, to: mixer, format: buffer.format)
        voice.player.volume = 0
        voice.player.scheduleBuffer(buffer, at: nil, options: .loops)
        voice.player.play()
        return voice
    }

    /// A loop of the kind, made the first time it's wanted and kept: twelve seconds of stereo noise, the two channels
    /// made from different random streams so it sounds wide rather than inside the head.
    private func buffer(_ kind: NoiseKind, rate: Double) -> AVAudioPCMBuffer? {
        if let made = buffers[kind], made.format.sampleRate == rate { return made }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return nil }
        let left = NoiseLoop.channel(kind, sampleRate: rate, seed: UInt64.random(in: 1...UInt64.max))
        let right = NoiseLoop.channel(kind, sampleRate: rate, seed: UInt64.random(in: 1...UInt64.max))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: right.count) }
        buffers[kind] = buffer
        return buffer
    }

    private func startEngine() -> AVAudioEngine? {
        if let engine { return engine }
        let engine = AVAudioEngine()
        engine.attach(mixer)
        engine.attach(lowPass)
        let band = lowPass.bands[0]
        band.filterType = .lowPass
        band.frequency = cutoff
        band.bypass = false
        lowPass.globalGain = 0
        let format = engine.outputNode.outputFormat(forBus: 0)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)
        engine.connect(mixer, to: lowPass, format: stereo)
        engine.connect(lowPass, to: engine.mainMixerNode, format: stereo)
        mixer.outputVolume = master
        do {
            try engine.start()
        } catch {
            NSLog("Sand Timer: couldn't start the focus noise: \(error)")
            return nil
        }
        self.engine = engine
        return engine
    }

    private func stopEngine() {
        ramp?.invalidate()
        ramp = nil
        guard let engine else { return }
        engine.stop()
        voices.forEach { engine.detach($0.player) }
        self.engine = nil
        master = 0
    }

    /// Moves every level a little toward where it's heading, a hundred times a second, while anything is moving:
    /// voices fade at their own pace, the volume follows the slider within about 30 ms and the softness within 50.
    private func startRamping() {
        guard ramp == nil, engine != nil else { return }
        let timer = Timer(timeInterval: Self.step, repeats: true) { [weak self] _ in self?.stepRamps() }
        RunLoop.main.add(timer, forMode: .common)
        ramp = timer
    }

    private func stepRamps() {
        let dt = Float(Self.step)
        if let until = previewUntil, until <= Date() {
            previewUntil = nil
            update()
        }
        var moving = false
        for voice in voices {
            let change = voice.rate * dt
            voice.level = voice.target > voice.level ? min(voice.target, voice.level + change) : max(voice.target, voice.level - change)
            voice.player.volume = voice.level
            if voice.level != voice.target { moving = true }
        }
        // Voices that have faded away are let go.
        for voice in voices where voice.target == 0 && voice.level == 0 {
            voice.player.stop()
            engine?.detach(voice.player)
        }
        voices.removeAll { $0.target == 0 && $0.level == 0 }

        let wantedGain = NoiseLoop.gain(volume: volume)
        master += (wantedGain - master) * min(1, dt / 0.03)
        if abs(master - wantedGain) < 0.0005 { master = wantedGain } else { moving = true }
        mixer.outputVolume = master
        let wantedCutoff = NoiseLoop.cutoff(softness: softness)
        cutoff += (wantedCutoff - cutoff) * min(1, dt / 0.05)
        if abs(cutoff - wantedCutoff) < 1 { cutoff = wantedCutoff } else { moving = true }
        lowPass.bands[0].frequency = cutoff
        lowPass.bands[0].bypass = cutoff >= 19_999  // fully open: leave the sound untouched

        if voices.isEmpty {
            stopEngine()  // nothing left to hear: give the audio hardware back
        } else if !moving && previewUntil == nil {
            ramp?.invalidate()
            ramp = nil
        }
    }
}
