import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaTranscription

/// The check that catches a transcript written in a language nobody spoke.
///
/// With detection off and a mismatched locale, whisper's decoder does not fail
/// and does not fall silent — it writes fluent text in the language it was
/// asked for. Measured in the field in both directions: English speech asked
/// for as `es-ES` came out as fluent Spanish, and Spanish speech asked for as
/// `en-US` came out as fluent English, on base and small, on Windows and on
/// Linux, with `params.translate = false` the whole time.
///
/// Nothing downstream can see it, so these tests guard the only thing that
/// can. Unit speed, no model: a stub returns fixed likelihoods and this
/// establishes what is done with them. `MixedLanguageMeasurement` establishes
/// what the probabilities actually are on real audio.
@Suite("Language mismatch check")
struct LanguageMismatchTests {

    /// Counts its calls, so a test can assert the expensive one was *not*
    /// made. A check that quietly asks the engine on every job when it did not
    /// need to is a cost nobody would notice in an assertion about the answer.
    private actor StubEngine: TranscriptionEngine {
        let identifier = EngineID.whisper
        private let answer: [LanguageLikelihood]
        private let failing: Bool
        private(set) var asked = 0

        init(_ answer: [LanguageLikelihood], failing: Bool = false) {
            self.answer = answer
            self.failing = failing
        }

        func capabilities() async -> EngineCapabilities {
            EngineCapabilities(supportsWordTimestamps: true,
                               supportedLocales: ShippingLanguages.set,
                               localeSelectedPerCall: true)
        }
        func prepare(locale: String) async throws {}
        func release() async {}
        func identifyLanguage(_ range: SampleRange,
                              in canonicalFile: URL) async throws -> [LanguageLikelihood] {
            asked += 1
            if failing {
                throw VoxScriptaError.engineUnavailable(.whisper, reason: "test")
            }
            return answer
        }
        func transcribe(_ range: SampleRange, in canonicalFile: URL,
                        options: TranscriptionOptions) async throws -> [TranscriptSegment] {
            []
        }
    }

    private static func likelihoods(es: Double, en: Double) -> [LanguageLikelihood] {
        [LanguageLikelihood(locale: "es-ES", probability: es),
         LanguageLikelihood(locale: "en-US", probability: en)]
            .sorted { $0.probability > $1.probability }
    }

    // MARK: - The defect, in both directions

    @Test("English audio asked for as Spanish warns")
    func englishAudioSpanishLocale() {
        // The measured figure for single-language English.
        let verdict = LanguageProbe.check(Self.likelihoods(es: 0.0006, en: 0.9994),
                                          requested: "es-ES")
        #expect(verdict == .mismatch("en"))
    }

    @Test("Spanish audio asked for as English warns")
    func spanishAudioEnglishLocale() {
        // The direction the Windows session found second. The same mechanism
        // produces it, so the same check has to catch it; a rule written for
        // one direction would have passed everything here.
        let verdict = LanguageProbe.check(Self.likelihoods(es: 0.9987, en: 0.0006),
                                          requested: "en-US")
        #expect(verdict == .mismatch("es"))
    }

    // MARK: - What must not warn

    @Test("A different region of the same language is not a mismatch",
          arguments: ["es-MX", "es-ES", "es-419"])
    func regionIsNotLanguage(locale: String) {
        // Whisper identifies languages, not regions. Warning that `es-ES`
        // audio "looks like Spanish" when Spanish is what was asked for would
        // train the user to ignore the note that matters.
        let verdict = LanguageProbe.check(Self.likelihoods(es: 0.9987, en: 0.0006),
                                          requested: locale)
        #expect(verdict == .matches)
    }

    @Test("An answer the model is unsure of is not a verdict",
          arguments: [0.8546, 0.8091, 0.5])
    func unsureDoesNotWarn(probability: Double) {
        // A recording that changes language halfway scores here. There is no
        // single correct language for it, so there is nothing to warn about —
        // and `unchecked` says so rather than claiming agreement.
        //
        // These are Spanish probabilities against a request for English, so a
        // low one is not another case to add here: `es: 0.0` means the head is
        // *certain* the audio is English, which is what was asked for, and the
        // answer is `.matches`. The first draft of this test listed it, and
        // the failure was the test's rather than the rule's.
        let verdict = LanguageProbe.check(
            Self.likelihoods(es: probability, en: 1 - probability), requested: "en-US")
        guard case .unchecked = verdict else {
            Issue.record("expected unchecked, got \(verdict)")
            return
        }
    }

    @Test("A language the app does not ship warns about neither")
    func unshippedLanguageIsUnchecked() {
        // WhisperEngine.identifyLanguage reports only the shipping locales,
        // taking each probability from whisper's own full-vocabulary softmax
        // rather than renormalising across those two. So Japanese audio scores
        // low for both and the user's setting stands. Pinned here because a
        // future renormalisation would turn this into a confident wrong
        // warning — `en` at 0.5/(0.5+0.5) reads as certainty.
        let verdict = LanguageProbe.check(Self.likelihoods(es: 0.004, en: 0.011),
                                          requested: "en-US")
        guard case .unchecked = verdict else {
            Issue.record("expected unchecked, got \(verdict)")
            return
        }
    }

    @Test("No language head at all is unchecked, not agreement")
    func emptyIsUnchecked() {
        // Apple's recogniser returns empty. That is "cannot tell", and
        // reporting it as a match would claim a recording was verified by
        // something that never looked at it.
        guard case .unchecked = LanguageProbe.check([], requested: "en-US") else {
            Issue.record("empty likelihoods must not read as a match")
            return
        }
    }

    @Test("The threshold is the one detection uses")
    func thresholdMatchesDetection() {
        // Reused deliberately: at any probability that would make `detect`
        // switch the whole job to Spanish, this must warn that it looks
        // Spanish. If the two drift apart, the same evidence starts meaning
        // two different things depending on a setting.
        let at = LanguageProbe.minimumLanguageProbability
        #expect(LanguageProbe.check(Self.likelihoods(es: at, en: 1 - at),
                                    requested: "en-US") == .mismatch("es"))
        let under = at - 0.0001
        guard case .unchecked = LanguageProbe.check(
            Self.likelihoods(es: under, en: 1 - under), requested: "en-US") else {
            Issue.record("just under the threshold must not warn")
            return
        }
    }

    // MARK: - unchecked is not a pass

    @Test("Only a mismatch reads as a mismatch")
    func isMismatchIsNarrow() {
        #expect(LanguageProbe.MismatchCheck.mismatch("es").isMismatch)
        #expect(LanguageProbe.MismatchCheck.matches.isMismatch == false)
        #expect(LanguageProbe.MismatchCheck.unchecked(reason: "no language head")
                    .isMismatch == false)
    }

    // MARK: - Asking a real engine

    private static let speech = [TimeRange(start: .zero, duration: .seconds(60))]

    @Test("A prepared engine is asked once and not released")
    func asksTheEngineOnce() async {
        let engine = StubEngine(Self.likelihoods(es: 0.0006, en: 0.9994))
        let verdict = await LanguageProbe.check(
            in: URL(filePath: "/dev/null"), speech: Self.speech,
            requested: "es-ES", using: engine)
        #expect(verdict == .mismatch("en"))
        #expect(await engine.asked == 1)
    }

    @Test("A head that throws leaves the job alone")
    func throwingHeadIsUnchecked() async {
        // A check that cannot run must not fail a job that can — the
        // transcript is still a transcript. But it has to say it did not run.
        let engine = StubEngine([], failing: true)
        let verdict = await LanguageProbe.check(
            in: URL(filePath: "/dev/null"), speech: Self.speech,
            requested: "es-ES", using: engine)
        guard case .unchecked = verdict else {
            Issue.record("a thrown error must read as unchecked, got \(verdict)")
            return
        }
    }

    @Test("Too little speech does not reach the engine")
    func silenceIsNotSampled() async {
        let engine = StubEngine(Self.likelihoods(es: 0.0006, en: 0.9994))
        let verdict = await LanguageProbe.check(
            in: URL(filePath: "/dev/null"),
            speech: [TimeRange(start: .zero, duration: .milliseconds(200))],
            requested: "es-ES", using: engine)
        guard case .unchecked = verdict else {
            Issue.record("expected unchecked, got \(verdict)")
            return
        }
        #expect(await engine.asked == 0, "no sample means no encoder pass")
    }
}
