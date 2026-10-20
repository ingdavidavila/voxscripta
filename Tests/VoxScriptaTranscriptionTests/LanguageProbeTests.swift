import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaTranscription

/// The rule that decides what language a recording is in.
///
/// Tested apart from the audio because the probing is mechanical and the rule
/// is where the judgement lives — and the first version of the rule was wrong.
@Suite("Language probe")
struct LanguageProbeTests {

    private func score(_ locale: String, _ words: Int, _ confidence: Double)
        -> LanguageProbe.Score {
        LanguageProbe.Score(locale: locale, words: words, confidence: confidence)
    }

    @Test("The real measurement decides correctly")
    func realMeasurement() {
        // From the recording that started this: Spanish audio, probed in both
        // languages. The engine returns words either way — it does not fall
        // silent on the wrong language — but it knows when it is guessing.
        let decided = LanguageProbe.decide([
            score("en-US", 37, 0.08),
            score("es-ES", 50, 0.93),
        ])
        #expect(decided == "es-ES")
    }

    @Test("Word count alone would have got it wrong")
    func wordCountIsNotEnough() {
        // 50 against 37 is a ratio of 1.35, nowhere near decisive. Had the
        // rule counted words it would have declined to choose, and the user
        // would have got the empty English transcript again.
        let byWords = [score("en-US", 37, 1), score("es-ES", 50, 1)]
        #expect(LanguageProbe.decide(byWords) == nil)
    }

    @Test("A close call is left to the user")
    func ambiguityDeclines() {
        // Two plausible readings is not a detection. Overriding someone's own
        // setting on a coin toss is worse than leaving it alone.
        #expect(LanguageProbe.decide([
            score("en-US", 40, 0.80),
            score("es-ES", 42, 0.78),
        ]) == nil)
    }

    @Test("Too little output decides nothing")
    func sparseOutputDeclines() {
        #expect(LanguageProbe.decide([
            score("en-US", 2, 0.95),
            score("es-ES", 1, 0.10),
        ]) == nil)
        #expect(LanguageProbe.decide([]) == nil)
    }

    @Test("A single candidate still has to earn it")
    func singleCandidate() {
        #expect(LanguageProbe.decide([score("es-ES", 50, 0.93)]) == "es-ES")
        // Confidence of zero means the engine recognised nothing it believed.
        #expect(LanguageProbe.decide([score("es-ES", 50, 0)]) == nil)
    }

    @Test("The sample comes from the middle of the speech")
    func samplesFromTheMiddle() {
        // Recordings open with room tone and "testing, testing", which
        // identifies no language at all.
        let speech = [TimeRange(start: .seconds(0), end: .seconds(120))]
        let range = LanguageProbe.sampleRange(from: speech, sampleRate: 16_000)
        let sample = try! #require(range)
        let start = MediaTime(samples: sample.start, sampleRate: 16_000)
        #expect(start > .seconds(40), "sample should not start at the beginning")
        #expect(sample.count == LanguageProbe.sampleDuration.samples(at: 16_000))
    }

    @Test("A recording shorter than the sample is still probed")
    func shortRecording() {
        let speech = [TimeRange(start: .seconds(0), end: .seconds(5))]
        let sample = try! #require(LanguageProbe.sampleRange(from: speech, sampleRate: 16_000))
        #expect(sample.count == MediaTime.seconds(5).samples(at: 16_000))
    }

    @Test("Silence is not probed")
    func noSpeech() {
        #expect(LanguageProbe.sampleRange(from: [], sampleRate: 16_000) == nil)
        let blip = [TimeRange(start: .zero, end: .milliseconds(200))]
        #expect(LanguageProbe.sampleRange(from: blip, sampleRate: 16_000) == nil)
    }
}
