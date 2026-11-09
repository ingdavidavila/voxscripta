// Apple's recogniser and the speech corpus that feeds it, both of which are
// Apple's alone. The point of this file is a number, and the number is only
// meaningful on the platform that produces it.
#if canImport(Speech)
import Testing
import Foundation
import AVFoundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaBench
import VoxScriptaTestSupport
@testable import VoxScriptaTranscription

/// How accurate Spanish actually is.
///
/// English has had a word error rate since the engine was chosen — about 5.6%
/// on the standard corpus — and Spanish has had none. The app ships both
/// languages, so "Spanish is a little off" has been an impression with
/// nothing behind it: no way to tell a bad recording from a bad engine, and
/// no way to know whether a change helped.
///
/// This is the missing half of that measurement. It prints the rate and the
/// substitutions; the assertion only pins what the number has already shown,
/// in the manner of `OffAppleGauntletMeasurement`.
///
/// Skipped where there is no Spanish voice installed, because rendering
/// Spanish text with an English voice measures the voice rather than the
/// recogniser.
@Suite("Spanish accuracy", .serialized)
struct SpanishAccuracyMeasurement {

    static var hasSpanishVoice: Bool {
        AVSpeechSynthesisVoice(language: "es-ES") != nil
    }

    private func measure(
        _ passages: [SpeechPassage],
        locale: String,
        language: String,
        scoring: TranscriptLanguage
    ) async throws -> (rate: Double, hypothesis: String, reference: String) {
        let tmp = try TempDirectory()
        let samples = try await SpeechCorpus.render(passages, language: language)
        let wav = tmp.url.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: samples, to: wav, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)

        let canonical = tmp.url.appending(path: "canonical.f32")
        let written = try await CanonicalDecoder().decode(url: wav, to: canonical) { _ in }

        let engine = AppleSpeechEngine()
        try await engine.prepare(locale: locale)
        defer { Task { await engine.release() } }

        var options = TranscriptionOptions.default
        options.locale = locale
        let segments = try await engine.transcribe(
            SampleRange(start: 0, count: written), in: canonical, options: options)

        let hypothesis = segments.map(\.text).joined(separator: " ")
        let reference = SpeechCorpus.referenceText(for: passages)
        // The scoring language is not optional in practice, whatever its
        // default says. Without it "quinientas" is not folded to 500 and a
        // correct Spanish transcription is charged for writing the number the
        // way every engine writes it — which is the mistake the comment on
        // WordErrorRate.measure warns about, and the one this file made on
        // its first run: 11.1% that was mostly arithmetic notation.
        let result = WordErrorRate.measure(reference: reference, hypothesis: hypothesis,
                                           language: scoring)
        return (result.rate, hypothesis, reference)
    }

    @Test("Spanish, measured",
          .enabled(if: SpanishAccuracyMeasurement.hasSpanishVoice,
                   "no Spanish voice installed"))
    func spanish() async throws {
        let (rate, hypothesis, reference) = try await measure(
            SpeechCorpus.spanish, locale: "es-ES", language: "es-ES", scoring: .spanish)
        print("""

        SPANISH · es-ES, Apple engine
          word error rate: \(String(format: "%.1f", rate * 100))%
          reference:  \(reference)
          transcript: \(hypothesis)
        """)
        // Measured: 7.0%, against English's 5.6% on the same path. The gap is
        // 1.4 points, not the 5.5 the first run of this test reported — that
        // one scored Spanish under English number rules and charged it for
        // "500" against "quinientas".
        //
        // What is left is almost entirely proper nouns: "Sara Chen" comes
        // back as "Sarachen" and "Northwind" as "Norteña". Names are the hard
        // case in every recogniser, and they are also what the polish
        // validator's entity check exists to protect, so an error here is
        // visible downstream rather than silent.
        //
        // The bar allows for drift: synthesized speech is not bit-identical
        // across machines or OS versions, so this catches a regression rather
        // than pinning a figure.
        #expect(rate < 0.12, "Spanish word error rate \(rate)")
    }

    @Test("English, the same measurement, for comparison",
          .enabled(if: SpanishAccuracyMeasurement.hasSpanishVoice,
                   "no Spanish voice installed"))
    func englishForComparison() async throws {
        // Measured here as well as in SmokeTests, because a Spanish number
        // alone says nothing: the two have to come off the same corpus shape,
        // the same renderer and the same engine settings to be comparable.
        let (rate, _, _) = try await measure(
            SpeechCorpus.standard, locale: "en-US", language: "en-US", scoring: .english)
        print("""

        ENGLISH · en-US, Apple engine, same path
          word error rate: \(String(format: "%.1f", rate * 100))%
        """)
        // Measured: 5.6%, which matches the figure the engine was chosen on.
        #expect(rate < 0.10, "English word error rate \(rate)")
    }
}
#endif
