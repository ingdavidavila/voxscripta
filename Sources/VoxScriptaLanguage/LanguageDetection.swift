import Foundation
import NaturalLanguage
import VoxScriptaCore

/// Checks that a transcript is plausibly in the language it was transcribed as.
///
/// This exists because of a silent failure. A Spanish recording transcribed as
/// `en-US` produced fifty-three characters of commas — no words at all — and
/// the app presented that as a finished transcript. The engine was not broken
/// and nothing threw; it simply found no English in Spanish audio. The result
/// was indistinguishable from success to every part of the pipeline.
///
/// Two checks, because the two failures look different. A transcript with no
/// words at all is not a result and must not be offered as one. A transcript
/// that reads fluently in the wrong language is a result, just not the one
/// asked for, and deserves a warning rather than an error.
public enum LanguageDetection {

    /// What the text looks like, regardless of what was asked for.
    ///
    /// Returns `nil` when there is too little text to judge. The recognizer
    /// will happily name a language for three words, and being wrong here
    /// means telling someone their correct transcript is in the wrong
    /// language, so the floor is deliberately high.
    public static func dominantLanguage(of text: String,
                                        minimumWords: Int = 12) -> (code: String,
                                                                    confidence: Double)? {
        let words = TextTokenizer.tokens(text)
        guard words.count >= minimumWords else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return (language.rawValue, confidence)
    }

    /// Why a transcript looks wrong, or `nil` when it looks fine.
    ///
    /// - Parameters:
    ///   - text: The verbatim transcript.
    ///   - locale: The locale it was transcribed with.
    ///   - speechDuration: How much speech the detector found. Without this a
    ///     genuinely silent recording would be reported as a language failure.
    public static func diagnose(text: String,
                                locale: String,
                                speechDuration: MediaTime) -> Finding? {
        let words = TextTokenizer.tokens(text)
        let speechSeconds = speechDuration.seconds

        // The detector heard speech and the engine returned no words. Whatever
        // is in the recording, it is not the language being transcribed.
        if speechSeconds >= 3, words.isEmpty {
            return .noWordsRecognized(locale: locale, speechSeconds: speechSeconds)
        }

        // Far too few words for the amount of speech. Ten a minute is roughly
        // a twelfth of a slow speaker, so this does not fire on a quiet
        // recording — only on one that mostly failed.
        if speechSeconds >= 30, Double(words.count) / (speechSeconds / 60) < 10 {
            return .tooFewWords(locale: locale, words: words.count,
                                speechSeconds: speechSeconds)
        }

        guard let detected = dominantLanguage(of: text), detected.confidence >= 0.75 else {
            return nil
        }
        let expected = locale.split(separator: "-").first.map(String.init)?.lowercased()
        guard let expected, detected.code.lowercased() != expected else { return nil }
        return .languageMismatch(locale: locale, detected: detected.code,
                                 confidence: detected.confidence)
    }

    public enum Finding: Sendable, Equatable {
        /// Speech was present and nothing was recognised.
        case noWordsRecognized(locale: String, speechSeconds: Double)
        /// Some words, but far fewer than the speech accounts for.
        case tooFewWords(locale: String, words: Int, speechSeconds: Double)
        /// A fluent transcript, in a different language than requested.
        case languageMismatch(locale: String, detected: String, confidence: Double)

        /// Whether this should stop the job rather than annotate it.
        ///
        /// Only the empty case stops. The others produce something a person
        /// can read and judge, and refusing to show it would be worse than
        /// showing it with a warning attached.
        public var isFatal: Bool {
            if case .noWordsRecognized = self { return true }
            return false
        }
    }
}
