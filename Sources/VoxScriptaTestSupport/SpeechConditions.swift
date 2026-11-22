import Foundation
import VoxScriptaCore

/// The acoustic conditions a real recording arrives in.
///
/// The corpus so far has been clean studio speech, which is the one condition
/// the app will rarely meet. Every bug found in the pipeline by hand — the
/// final word cut off a recording that ends as the speaking does, a noise
/// floor measured too high because nothing in the recording was ever quiet —
/// lived in a condition no fixture reproduced.
///
/// Generated rather than recorded, for the same reason the rest of this
/// project's corpora are: ground truth is then exact, nothing needs a
/// licence, and nobody's voice is in the repository. A condition is a
/// deterministic transform of rendered speech, so the same seed gives the
/// same audio on every machine and a measurement can be compared with one
/// taken last month.
///
/// Pure arithmetic, deliberately. Rendering speech needs AVSpeechSynthesizer
/// and so only happens on Apple's platforms; conditioning does not, and runs
/// anywhere — which matters, because the platforms that need this corpus most
/// are the ones that cannot render it.
public enum SpeechCondition: Sendable, Hashable, Codable {
    /// Exactly as rendered. The control.
    case clean
    /// Spoken far from the microphone, or simply quietly.
    case quiet(gainDB: Double)
    /// Steady background sound at a measured signal-to-noise ratio.
    case noise(snrDB: Double, kind: NoiseKind)
    /// A tonal bed, as a recording made where music was playing.
    case music(snrDB: Double)
    /// Silence inserted between sentences, long enough to be a chunk boundary.
    case longPauses(seconds: Double)
    /// The recording stops as the speaking stops — a person tapping Stop.
    case abruptEnding
    /// The last word trails off instead of ending cleanly.
    case decayingFinalWord(fadeSeconds: Double)

    public enum NoiseKind: String, Sendable, Hashable, Codable, CaseIterable {
        /// Broadband hiss: air conditioning, a poor microphone.
        case hiss
        /// Mains hum and its harmonics, which sits under most indoor recordings.
        case hum
        /// Low rumble with a periodic beat: a fan, a fridge, a passing lorry.
        case machinery
    }

    /// What this condition is called in a report.
    public var name: String {
        switch self {
        case .clean: "clean"
        case .quiet(let dB): "quiet \(Int(dB)) dB"
        case .noise(let snr, let kind): "\(kind.rawValue) \(Int(snr)) dB SNR"
        case .music(let snr): "music \(Int(snr)) dB SNR"
        case .longPauses(let s): "pauses \(Int(s)) s"
        case .abruptEnding: "abrupt ending"
        case .decayingFinalWord: "decaying final word"
        }
    }

    /// A filename- and identifier-safe form of ``name``.
    ///
    /// Separate from `name` on purpose. `name` is for a person reading a report;
    /// this is for the key a result table is diffed on, and a key with spaces in
    /// it stops being diffable the first time someone pastes it into a shell.
    public var slug: String {
        switch self {
        case .clean: "clean"
        case .quiet(let dB): "quiet_\(Int(abs(dB)))dB"
        case .noise(let snr, let kind): "\(kind.rawValue)_\(Int(snr))dB"
        case .music(let snr): "music_\(Int(snr))dB"
        case .longPauses(let s): "pauses_\(Int(s))s"
        case .abruptEnding: "abrupt_end"
        case .decayingFinalWord(let fade): "decay_\(Int(fade * 10))"
        }
    }
}

/// Applies conditions to rendered speech.
public enum SpeechConditioning {

    /// Room tone, so that "silence" is never digital zero.
    ///
    /// A detector tuned against pure zeros is not a detector, and a noise
    /// floor measured from them is not a floor. Every condition keeps some.
    public static let roomToneDB = -62.0

    public static func apply(
        _ condition: SpeechCondition,
        to samples: [Float],
        sampleRate: Int = CanonicalFormat.sampleRate,
        seed: UInt64 = 0x5EED_C0DE
    ) -> [Float] {
        guard !samples.isEmpty else { return samples }
        switch condition {
        case .clean:
            return samples
        case .quiet(let gainDB):
            let scale = Float(pow(10.0, gainDB / 20.0))
            return samples.map { $0 * scale }
        case .noise(let snrDB, let kind):
            return mix(samples, with: noise(kind: kind, count: samples.count,
                                            sampleRate: sampleRate, seed: seed),
                       atSNR: snrDB)
        case .music(let snrDB):
            return mix(samples, with: musicBed(count: samples.count, sampleRate: sampleRate),
                       atSNR: snrDB)
        case .longPauses(let seconds):
            return insertingPauses(into: samples, seconds: seconds,
                                   sampleRate: sampleRate, seed: seed)
        case .abruptEnding:
            return trimmingTrailingQuiet(samples)
        case .decayingFinalWord(let fadeSeconds):
            return fadingTail(samples, seconds: fadeSeconds, sampleRate: sampleRate)
        }
    }

    // MARK: - Level

    /// Root mean square, the level everything here is measured against.
    public static func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    public static func rms(_ samples: [Float]) -> Double { rms(samples[...]) }

    /// Scales `background` so that mixing it under `speech` lands on `snrDB`,
    /// then mixes. The ratio is asserted in the tests rather than assumed.
    static func mix(_ speech: [Float], with background: [Float], atSNR snrDB: Double) -> [Float] {
        let speechLevel = rms(speech)
        let backgroundLevel = rms(background)
        guard speechLevel > 0, backgroundLevel > 0 else { return speech }

        let wanted = speechLevel / pow(10.0, snrDB / 20.0)
        let scale = Float(wanted / backgroundLevel)
        return zip(speech, background).map { $0 + $1 * scale }
    }

    // MARK: - Backgrounds

    static func noise(kind: SpeechCondition.NoiseKind,
                      count: Int, sampleRate: Int, seed: UInt64) -> [Float] {
        var rng = DeterministicRandom(seed: seed)
        let rate = Double(sampleRate)

        switch kind {
        case .hiss:
            return (0..<count).map { _ in Float(rng.gaussian() * 0.1) }

        case .hum:
            // 60 Hz and the harmonics that come with it. Narrow-band and
            // steady, which is the hard case for a noise floor estimated
            // from energy alone: it never goes quiet.
            return (0..<count).map { i in
                let t = Double(i) / rate
                let fundamental = sin(2 * .pi * 60 * t)
                let second = 0.4 * sin(2 * .pi * 120 * t)
                let third = 0.2 * sin(2 * .pi * 180 * t)
                return Float((fundamental + second + third) * 0.1)
            }

        case .machinery:
            // Low rumble with a slow beat, as a fan or a fridge compressor:
            // broadband enough to mask consonants, modulated enough that a
            // detector can mistake the modulation for speech.
            return (0..<count).map { i in
                let t = Double(i) / rate
                let rumble = sin(2 * .pi * 48 * t) + 0.6 * sin(2 * .pi * 95 * t)
                let beat = 0.5 + 0.5 * sin(2 * .pi * 1.7 * t)
                let grit = rng.gaussian() * 0.25
                return Float((rumble * beat + grit) * 0.08)
            }
        }
    }

    /// A tonal bed standing in for music.
    ///
    /// Four sustained notes moving through a progression, which is enough to
    /// be harmonically dense and continuous — the two properties that make
    /// music hard for a speech detector. Synthesised because a real recording
    /// would need a licence, and because a fixture nobody can regenerate is
    /// not a fixture.
    static func musicBed(count: Int, sampleRate: Int) -> [Float] {
        let rate = Double(sampleRate)
        let chords: [[Double]] = [
            [220.00, 277.18, 329.63],
            [196.00, 246.94, 293.66],
            [174.61, 220.00, 261.63],
            [164.81, 207.65, 246.94],
        ]
        let barSeconds = 2.0
        return (0..<count).map { i in
            let t = Double(i) / rate
            let chord = chords[Int(t / barSeconds) % chords.count]
            // A soft attack each bar, so it reads as played rather than held.
            let phase = t.truncatingRemainder(dividingBy: barSeconds) / barSeconds
            let envelope = 1 - exp(-phase * 12)
            let voices = chord.reduce(0.0) { $0 + sin(2 * .pi * $1 * t) }
            return Float(voices / Double(chord.count) * envelope * 0.25)
        }
    }

    // MARK: - Structure

    /// Inserts a pause of `seconds` at each sentence boundary it can find.
    ///
    /// Boundaries are found acoustically rather than from the transcript, so
    /// this works on any rendered speech: the quietest runs that already look
    /// like gaps are lengthened, which keeps the words in the same order and
    /// the reference transcript unchanged.
    static func insertingPauses(into samples: [Float], seconds: Double,
                                sampleRate: Int, seed: UInt64) -> [Float] {
        let window = sampleRate / 50                     // 20 ms
        guard window > 0, samples.count > window * 4 else { return samples }

        let speechLevel = rms(samples)
        let quietBelow = speechLevel * 0.08
        let padding = Int(seconds * Double(sampleRate))
        var rng = DeterministicRandom(seed: seed &+ 1)
        let toneScale = pow(10.0, roomToneDB / 20.0)

        var out: [Float] = []
        out.reserveCapacity(samples.count + padding * 4)

        var index = 0
        var runStart = 0
        var runIsQuiet = false
        while index + window <= samples.count {
            let slice = samples[index..<(index + window)]
            let quiet = rms(slice) < quietBelow
            if quiet != runIsQuiet {
                out.append(contentsOf: samples[runStart..<index])
                // A gap already present gets lengthened; speech is left alone.
                if runIsQuiet, index - runStart >= window * 3 {
                    out.append(contentsOf: (0..<padding).map { _ in
                        Float(rng.gaussian() * toneScale)
                    })
                }
                runStart = index
                runIsQuiet = quiet
            }
            index += window
        }
        out.append(contentsOf: samples[runStart...])
        return out
    }

    /// Cuts everything after the last sample that carries real level.
    ///
    /// The recording then ends on the final word, which is what happens when
    /// a person taps Stop as they finish speaking — and is the shape that cost
    /// the last word of every transcript until the chunk planner was fixed.
    static func trimmingTrailingQuiet(_ samples: [Float]) -> [Float] {
        let threshold = Float(rms(samples) * 0.05)
        guard let last = samples.lastIndex(where: { abs($0) > threshold }) else {
            return samples
        }
        return Array(samples[...last])
    }

    /// Fades the final `seconds` to nothing, as a speaker trailing off.
    ///
    /// Distinct from an abrupt ending: here the audio keeps running while the
    /// level falls through whatever the noise floor was measured to be, which
    /// is the case where a detector decides the last word was silence.
    static func fadingTail(_ samples: [Float], seconds: Double, sampleRate: Int) -> [Float] {
        let fade = Swift.min(Int(seconds * Double(sampleRate)), samples.count)
        guard fade > 1 else { return samples }
        var out = samples
        let start = samples.count - fade
        for i in 0..<fade {
            let progress = Double(i) / Double(fade - 1)
            // Exponential rather than linear: a voice decays that way, and a
            // linear ramp spends too long at an easily detected level.
            out[start + i] *= Float(exp(-progress * 5))
        }
        return out
    }
}
