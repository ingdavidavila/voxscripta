import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// The silent failure this exists to stop.
///
/// A Spanish recording transcribed as en-US returned fifty-three characters of
/// commas — no words — and the app presented it as a finished transcript. The
/// engine did not fail and nothing threw.
@Suite("Language detection")
struct LanguageDetectionTests {

    @Test("An empty result with speech present is fatal")
    func noWordsIsFatal() {
        // The exact output from the real failure.
        let finding = LanguageDetection.diagnose(
            text: ", , , , , , , , , , , , , , , , , , , , , , , , , , ,",
            locale: "en-US", speechDuration: .seconds(97))
        #expect(finding == .noWordsRecognized(locale: "en-US", speechSeconds: 97))
        #expect(finding?.isFatal == true)
    }

    @Test("Silence is not a language failure")
    func silenceIsNotAFailure() {
        // Without the speech-duration guard, a genuinely silent recording
        // would be reported as the wrong language.
        #expect(LanguageDetection.diagnose(text: "", locale: "en-US",
                                           speechDuration: .seconds(0)) == nil)
        #expect(LanguageDetection.diagnose(text: "", locale: "en-US",
                                           speechDuration: .seconds(1)) == nil)
    }

    @Test("A correct transcript is not flagged")
    func correctTranscriptPasses() {
        let spanish = """
            Están afuera en la cantina y es un día seco, es un día caluroso. Están \
            David y Raúl, los dos están afuera de la cantina, están hablando y están \
            desmontando sus caballos.
            """
        #expect(LanguageDetection.diagnose(text: spanish, locale: "es-MX",
                                           speechDuration: .seconds(30)) == nil)

        let english = """
            Good morning everyone. I wanted to discuss the budget for next quarter \
            because the figures we approved last time were wrong and we should fix them.
            """
        #expect(LanguageDetection.diagnose(text: english, locale: "en-US",
                                           speechDuration: .seconds(30)) == nil)
    }

    @Test("A fluent transcript in the wrong language warns rather than throws")
    func mismatchWarns() {
        let spanish = """
            Están afuera en la cantina y es un día seco, es un día caluroso. Están \
            David y Raúl, los dos están afuera de la cantina, están hablando y están \
            desmontando sus caballos.
            """
        let finding = LanguageDetection.diagnose(text: spanish, locale: "en-US",
                                                 speechDuration: .seconds(30))
        guard case .languageMismatch(_, let detected, _) = finding else {
            Issue.record("expected a mismatch, got \(String(describing: finding))")
            return
        }
        #expect(detected == "es")
        // Readable text is still worth showing; the reader judges it.
        #expect(finding?.isFatal == false)
    }

    @Test("Too little text to judge is left alone")
    func shortTextIsNotJudged() {
        // The recognizer will name a language for three words. Being wrong
        // here means telling someone a correct transcript is wrong.
        #expect(LanguageDetection.dominantLanguage(of: "Hola buenos días") == nil)
    }

    @Test("A mostly-failed transcription warns about the word count")
    func tooFewWordsWarns() {
        // Five words across two minutes of speech is not a transcript.
        let finding = LanguageDetection.diagnose(
            text: "uno dos tres cuatro cinco", locale: "es-ES",
            speechDuration: .seconds(120))
        guard case .tooFewWords(_, let words, _) = finding else {
            Issue.record("expected tooFewWords, got \(String(describing: finding))")
            return
        }
        #expect(words == 5)
        #expect(finding?.isFatal == false)
    }
}
