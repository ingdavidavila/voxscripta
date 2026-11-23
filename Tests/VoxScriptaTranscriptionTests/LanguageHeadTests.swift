import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaTranscription

/// The decision made on the model's own probabilities.
///
/// Unit speed, no model: a stub engine returns fixed likelihoods and the rule
/// is checked against them. The measurement on real audio
/// (`MixedLanguageMeasurement`) establishes what the probabilities *are*; this
/// establishes what is done with them, which is the part that can regress
/// silently.
@Suite("Language head")
struct LanguageHeadTests {

    private actor StubEngine: TranscriptionEngine {
        let identifier = EngineID.whisper
        private let answer: [LanguageLikelihood]
        init(_ answer: [LanguageLikelihood]) { self.answer = answer }

        func capabilities() async -> EngineCapabilities {
            EngineCapabilities(supportsWordTimestamps: true,
                               supportedLocales: ShippingLanguages.set,
                               localeSelectedPerCall: true)
        }
        func prepare(locale: String) async throws {}
        func release() async {}
        func identifyLanguage(_ range: SampleRange,
                              in canonicalFile: URL) async throws -> [LanguageLikelihood] {
            answer
        }
        func transcribe(_ range: SampleRange, in canonicalFile: URL,
                        options: TranscriptionOptions) async throws -> [TranscriptSegment] {
            []
        }
    }

    private func identify(_ likelihoods: [LanguageLikelihood],
                          candidates: [String] = ["en-US", "es-ES"]) async throws
        -> LanguageProbe.Outcome {
        try await LanguageProbe.identify(
            SampleRange(start: 0, count: 320_000),
            in: URL(filePath: "/dev/null"),
            using: StubEngine(likelihoods),
            candidates: candidates)
    }

    @Test("A confident answer is taken")
    func confidentIsTaken() async throws {
        // The measured figure for single-language audio.
        let outcome = try await identify([
            LanguageLikelihood(locale: "es-ES", probability: 0.9987),
            LanguageLikelihood(locale: "en-US", probability: 0.0006),
        ])
        #expect(outcome.locale == "es-ES")
        #expect(outcome.method == .modelLanguageHead)
        #expect(outcome.likelihoods.count == 2, "the probabilities travel with the answer")
    }

    @Test("The field-bug case is taken and the ambiguous ones are not",
          arguments: [(0.9814, true), (0.8546, false), (0.8091, false)])
    func thresholdSitsBetweenTheMeasuredCases(probability: Double, taken: Bool) async throws {
        // These are the three measured mixed-language cases. 0.9814 is
        // two-thirds Spanish with an English passage in the middle — the shape
        // of the field report, and the one that must be answered. 0.85 and
        // 0.81 are recordings that change language halfway, where there is no
        // correct answer and declining is right.
        let outcome = try await identify([
            LanguageLikelihood(locale: "es-ES", probability: probability),
            LanguageLikelihood(locale: "en-US", probability: 1 - probability),
        ])
        #expect((outcome.locale != nil) == taken,
                "\(probability) should \(taken ? "be" : "not be") decisive")
        #expect(outcome.method == .modelLanguageHead,
                "the head answered either way; only its confidence differed")
    }

    @Test("An engine with no language head falls through to probing")
    func noHeadFallsThrough() async throws {
        // Empty means "cannot tell", which is different from "unsure", and the
        // method says so — a caller reading provenance must be able to see
        // that the head was never consulted rather than consulted and doubted.
        let outcome = try await identify([])
        #expect(outcome.locale == nil)
        #expect(outcome.method == .transcriptionProbe)
    }

    @Test("A confident answer in a language nobody asked about is not an answer")
    func unaskedLanguageIsRefused() async throws {
        // Whisper knows about a hundred languages. If it is sure the audio is
        // Portuguese and the caller asked about English and Spanish, forcing
        // the nearest candidate would be worse than declining: the text stages
        // would then apply Spanish lexicons to Portuguese.
        let outcome = try await identify(
            [LanguageLikelihood(locale: "pt-BR", probability: 0.99)],
            candidates: ["en-US", "es-ES"])
        #expect(outcome.locale == nil)
        #expect(outcome.method == .modelLanguageHead)
    }

    @Test("A language maps to whichever of its locales was asked about")
    func languageMapsToTheOfferedLocale() async throws {
        // The head identifies languages, not regions, so es-ES and es-MX carry
        // the same probability. Answering with a locale the caller did not
        // offer would be a different kind of wrong.
        let outcome = try await identify(
            [LanguageLikelihood(locale: "es-ES", probability: 0.99)],
            candidates: ["en-US", "es-MX"])
        #expect(outcome.locale == "es-MX")
    }

    @Test("The threshold is where the measurement put it")
    func thresholdIsDocumented() {
        // Pinned so that moving it is a deliberate act with a measurement
        // behind it, rather than a tweak to make a test pass.
        #expect(LanguageProbe.minimumLanguageProbability == 0.90)
    }
}
