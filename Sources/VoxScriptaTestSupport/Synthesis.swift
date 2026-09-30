import Foundation
import VoxScriptaCore

/// A reproducible pseudo-random source.
///
/// The test corpus must be byte-identical on every machine and every run, so
/// nothing here may touch the system random number generator. This is a plain
/// linear congruential generator — statistically unremarkable, which does not
/// matter for shaping test noise, and exactly reproducible, which does.
public struct DeterministicRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    public mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    /// Uniform in `0..<1`.
    public mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Uniform in `-1...1`.
    public mutating func bipolar() -> Double { uniform() * 2 - 1 }

    /// Approximately standard normal, via the central limit theorem.
    public mutating func gaussian() -> Double {
        var sum = 0.0
        for _ in 0..<6 { sum += uniform() }
        return (sum - 3) / 0.7071
    }
}

/// What a span of synthesized audio contains.
public enum SignalKind: String, Sendable, Codable {
    /// Voiced speech: a harmonic stack under a syllable-rate envelope.
    case voiced
    /// Unvoiced speech: shaped noise. Low energy, high zero-crossing rate —
    /// the case a naive RMS gate truncates.
    case fricative
    /// Voiced speech with brief stop-consonant closures cut into it. The
    /// closures must not be treated as pauses.
    case voicedWithClosures
    /// Room tone only.
    case silence
}

/// One span of a synthesized recording, with its intended classification.
public struct SignalSpan: Sendable, Codable {
    public let kind: SignalKind
    public let range: TimeRange
    /// Nominal level in dBFS.
    public let levelDB: Double

    public init(kind: SignalKind, range: TimeRange, levelDB: Double) {
        self.kind = kind
        self.range = range
        self.levelDB = levelDB
    }

    /// Whether the detector is expected to classify this span as speech.
    public var isSpeech: Bool { kind != .silence }
}

/// Renders spans into canonical-rate float samples.
///
/// The signal is not real speech, and does not need to be: the silence detector
/// keys on energy, zero-crossing rate and spectral flatness, and this synthesizer
/// reproduces those characteristics exactly and reproducibly. Word-error testing
/// uses real synthesized speech instead (`SpeechCorpus`, Phase 2).
public struct SignalSynthesizer: Sendable {
    public let sampleRate: Int
    public let seed: UInt64

    public init(sampleRate: Int = CanonicalFormat.sampleRate, seed: UInt64 = 0x0C7A_5EED) {
        self.sampleRate = sampleRate
        self.seed = seed
    }

    /// Renders a full recording from an ordered, contiguous list of spans.
    /// Renders spans, optionally ramping the room tone from `noiseFloorDB` to
    /// `noiseFloorEndDB` across the recording.
    public func render(
        spans: [SignalSpan],
        noiseFloorDB: Double = -62,
        noiseFloorEndDB: Double? = nil
    ) -> [Float] {
        let totalDuration = spans.last?.range.end ?? .zero
        let count = Int(totalDuration.samples(at: sampleRate))
        guard count > 0 else { return [] }

        var out = [Float](repeating: 0, count: count)
        var rng = DeterministicRandom(seed: seed)

        // Room tone everywhere, so "silence" is never digital zero — a detector
        // that only works against pure zeros is not a detector.
        let endDB = noiseFloorEndDB ?? noiseFloorDB
        for i in 0..<count {
            let t = Double(i) / Double(count)
            let levelDB = noiseFloorDB + (endDB - noiseFloorDB) * t
            out[i] = Float(rng.gaussian() * pow(10, levelDB / 20) * 0.3)
        }

        for span in spans {
            let start = Int(span.range.start.samples(at: sampleRate))
            let end = min(Int(span.range.end.samples(at: sampleRate)), count)
            guard end > start else { continue }
            let amplitude = pow(10, span.levelDB / 20)

            switch span.kind {
            case .silence:
                continue
            case .voiced:
                addVoiced(&out, start: start, end: end, amplitude: amplitude, rng: &rng)
            case .fricative:
                addFricative(&out, start: start, end: end, amplitude: amplitude, rng: &rng)
            case .voicedWithClosures:
                addVoicedWithClosures(&out, start: start, end: end, amplitude: amplitude, rng: &rng)
            }
        }
        return out
    }

    // MARK: - Generators

    /// A harmonic stack at ~120 Hz under a 4 Hz syllable envelope.
    ///
    /// The envelope never reaches zero, because real speech does not fall silent
    /// between syllables — and a detector tuned against an envelope that does
    /// will fragment on real audio.
    private func addVoiced(
        _ out: inout [Float], start: Int, end: Int,
        amplitude: Double, rng: inout DeterministicRandom
    ) {
        let f0 = 120.0
        let harmonics = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        let weights = [1.0, 0.6, 0.42, 0.22, 0.13, 0.07]
        let sr = Double(sampleRate)

        for i in start..<end {
            let t = Double(i - start) / sr
            // Continuous speech varies about 12 dB within a syllable at ~4 Hz.
            // Deeper than that and every above-threshold run falls below
            // minSpeechDuration, which is a property of the synthesizer rather
            // than of speech. Real inter-word silence is modelled by explicit
            // silence spans, not by the envelope.
            let raised = 0.5 + 0.5 * sin(2 * .pi * 4.0 * t)
            let syllable = 0.25 + 0.75 * pow(raised, 1.4)
            var sample = 0.0
            for (h, w) in zip(harmonics, weights) {
                sample += w * sin(2 * .pi * f0 * h * t)
            }
            sample /= 2.44   // normalize the harmonic sum
            let jitter = 1 + rng.bipolar() * 0.02
            out[i] += Float(sample * syllable * amplitude * jitter)
        }
    }

    /// High-frequency shaped noise: low energy, high ZCR, high spectral flatness.
    ///
    /// This is the signal that fricative protection exists for. A plain energy
    /// gate cuts it, and the transcript loses its plurals and possessives.
    private func addFricative(
        _ out: inout [Float], start: Int, end: Int,
        amplitude: Double, rng: inout DeterministicRandom
    ) {
        var previous = 0.0
        for i in start..<end {
            let white = rng.gaussian()
            // First-order high-pass: emphasizes the 4–8 kHz region where
            // sibilance lives, and drives the zero-crossing rate up.
            let highPassed = white - previous * 0.85
            previous = white
            out[i] += Float(highPassed * amplitude * 0.5)
        }
    }

    /// Voiced speech interrupted by 60 ms closures every 400 ms.
    ///
    /// Stop consonants (/p/, /t/, /k/) produce genuine near-silence inside a word.
    /// A detector that treats them as pauses splits words in half.
    private func addVoicedWithClosures(
        _ out: inout [Float], start: Int, end: Int,
        amplitude: Double, rng: inout DeterministicRandom
    ) {
        addVoiced(&out, start: start, end: end, amplitude: amplitude, rng: &rng)
        let closure = Int(0.060 * Double(sampleRate))
        let period = Int(0.400 * Double(sampleRate))
        var position = start + period
        while position + closure < end {
            for i in position..<(position + closure) {
                out[i] *= 0.02
            }
            position += period
        }
    }
}
