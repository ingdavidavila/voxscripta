import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport

/// Whether the corpus means what it says.
///
/// A fixture labelled "12 dB SNR" that is really at 4 dB does not expose a
/// weakness in the recogniser, it manufactures one — and every number measured
/// against it is wrong in a direction nobody can see. So each condition is
/// checked against its own claim before anything is measured with it.
///
/// Pure arithmetic, so these run on every platform, which is the point: the
/// platforms that most need this corpus are the ones that cannot render
/// speech to put through it.
@Suite("Speech conditions")
struct SpeechConditionTests {

    /// Speech-like rather than a tone: a sine has a flat envelope, and the
    /// pause finder and the trimmer both work on how the level moves.
    private func utterance(seconds: Double = 4, sampleRate: Int = 16_000) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        var rng = DeterministicRandom(seed: 0xA11CE)
        return (0..<count).map { i in
            let t = Double(i) / Double(sampleRate)
            // Three words, with real gaps between them.
            let inWord = t.truncatingRemainder(dividingBy: 1.2) < 0.7
            guard inWord else { return Float(rng.gaussian() * 0.0008) }
            let carrier = sin(2 * .pi * 180 * t) + 0.5 * sin(2 * .pi * 430 * t)
            return Float(carrier * 0.2 + rng.gaussian() * 0.01)
        }
    }

    @Test("Quiet speech is quieter by exactly the amount asked for",
          arguments: [-6.0, -12.0, -20.0])
    func quietIsTheStatedGain(gainDB: Double) {
        let original = utterance()
        let quiet = SpeechConditioning.apply(.quiet(gainDB: gainDB), to: original)

        let measured = 20 * log10(SpeechConditioning.rms(quiet)
                                  / SpeechConditioning.rms(original))
        #expect(abs(measured - gainDB) < 0.01,
                "asked for \(gainDB) dB, measured \(measured)")
        #expect(quiet.count == original.count, "gain must not change the length")
    }

    @Test("Noise lands on the signal-to-noise ratio it claims",
          arguments: [6.0, 12.0, 20.0])
    func noiseHitsItsSNR(snrDB: Double) {
        for kind in SpeechCondition.NoiseKind.allCases {
            let speech = utterance()
            let noisy = SpeechConditioning.apply(.noise(snrDB: snrDB, kind: kind), to: speech)

            // The noise that was added is the difference, which is the only
            // honest way to measure what actually went in.
            let added = zip(noisy, speech).map { $0 - $1 }
            let measured = 20 * log10(SpeechConditioning.rms(speech)
                                      / SpeechConditioning.rms(added))
            #expect(abs(measured - snrDB) < 0.5,
                    "\(kind.rawValue): asked for \(snrDB) dB, measured \(measured)")
        }
    }

    @Test("A music bed is mixed at its stated ratio and never goes silent")
    func musicIsContinuous() {
        let speech = utterance(seconds: 8)
        let mixed = SpeechConditioning.apply(.music(snrDB: 10), to: speech)
        let bed = zip(mixed, speech).map { $0 - $1 }

        let measured = 20 * log10(SpeechConditioning.rms(speech) / SpeechConditioning.rms(bed))
        #expect(abs(measured - 10) < 0.5, "music mixed at \(measured) dB, not 10")

        // Continuity is what makes music hard for a detector, so it is
        // asserted rather than assumed: every second carries level.
        let perSecond = stride(from: 0, to: bed.count - 16_000, by: 16_000).map {
            SpeechConditioning.rms(bed[$0..<($0 + 16_000)])
        }
        #expect(perSecond.allSatisfy { $0 > 0.01 },
                "a bed with a silent second is not a bed")
    }

    @Test("Long pauses lengthen the recording without touching the speech")
    func pausesLengthenGaps() {
        let original = utterance(seconds: 6)
        let paused = SpeechConditioning.apply(.longPauses(seconds: 2), to: original)

        #expect(paused.count > original.count, "pauses must add time")
        // Speech is untouched, so the total energy is unchanged — only
        // quiet was inserted. Within a whisker, for the room tone added.
        let before = SpeechConditioning.rms(original) * Double(original.count).squareRoot()
        let after = SpeechConditioning.rms(paused) * Double(paused.count).squareRoot()
        #expect(abs(after - before) / before < 0.01,
                "inserting silence must not change the speech energy")
    }

    @Test("An abrupt ending ends on the speech")
    func abruptEndingHasNoTail() {
        // A recording with a long quiet tail, as a synthesiser leaves.
        let speech = utterance(seconds: 3)
        let withTail = speech + [Float](repeating: 0.00005, count: 16_000 * 2)

        let trimmed = SpeechConditioning.apply(.abruptEnding, to: withTail)
        #expect(trimmed.count < withTail.count, "the tail must be gone")

        // What remains ends on real level rather than on quiet, which is the
        // whole condition: the file stops when the speaking stops.
        let lastTenth = trimmed[(trimmed.count - trimmed.count / 10)...]
        #expect(SpeechConditioning.rms(lastTenth) > SpeechConditioning.rms(withTail) * 0.1,
                "the end of the file must carry speech")
    }

    @Test("A decaying final word falls away without being cut")
    func decayFadesRatherThanTruncates() {
        let original = utterance(seconds: 4)
        let decayed = SpeechConditioning.apply(.decayingFinalWord(fadeSeconds: 1), to: original)

        #expect(decayed.count == original.count, "a fade must not shorten the file")

        // The level falls across the fade: the end is far quieter than the
        // start of it, which is the case a noise floor gets wrong.
        let fadeStart = decayed.count - 16_000
        let head = SpeechConditioning.rms(decayed[fadeStart..<(fadeStart + 2_000)])
        let tail = SpeechConditioning.rms(decayed[(decayed.count - 2_000)...])
        #expect(tail < head * 0.1, "the tail must decay, measured \(tail) against \(head)")
        #expect(tail > 0, "a decay is not a truncation — it must not reach zero")
    }

    @Test("The same seed gives the same audio")
    func conditionsAreReproducible() {
        // A corpus that differs run to run cannot be compared with itself,
        // which is most of what a corpus is for.
        let speech = utterance()
        for condition: SpeechCondition in [
            .noise(snrDB: 10, kind: .hiss),
            .noise(snrDB: 10, kind: .machinery),
            .music(snrDB: 10),
            .longPauses(seconds: 1),
        ] {
            let a = SpeechConditioning.apply(condition, to: speech, seed: 42)
            let b = SpeechConditioning.apply(condition, to: speech, seed: 42)
            #expect(a == b, "\(condition.name) is not reproducible")
        }
    }

    @Test("Every condition names itself for a report")
    func conditionsAreNamed() {
        let names: [SpeechCondition] = [
            .clean, .quiet(gainDB: -12), .noise(snrDB: 6, kind: .hum),
            .music(snrDB: 10), .longPauses(seconds: 3), .abruptEnding,
            .decayingFinalWord(fadeSeconds: 1),
        ]
        #expect(Set(names.map(\.name)).count == names.count,
                "two conditions sharing a name would merge two rows of results")
    }
}
