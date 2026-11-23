import Foundation
import VoxScriptaCore

/// Works out what language a recording is in, by trying.
///
/// There is no acoustic language identifier in the engine, but there does not
/// need to be: an engine asked for the wrong language returns almost nothing.
/// A Spanish recording transcribed as `en-US` produced fifty-three characters
/// of commas and no words at all, while the same audio as `es-ES` produced a
/// full transcript. That gap is the signal, and it is enormous — a wrong guess
/// scores near zero against hundreds of words for a right one.
///
/// So the probe transcribes a short sample in each candidate language and
/// counts the words. It costs a few seconds: transcription runs at roughly
/// 120× real time, so a twenty-second sample across three candidates is under
/// a second of work against a recording that may run for hours.
public enum LanguageProbe {

    /// What one candidate produced.
    public struct Score: Sendable, Hashable {
        public let locale: String
        public let words: Int
        /// The engine's own mean confidence across the sample.
        ///
        /// This, not the word count, is what separates recognition from
        /// phonetic guessing. Asked for the wrong language the engine does not
        /// fall silent on a short sample — it returns plausible-looking
        /// nonsense, and on the recording that prompted all this it returned
        /// 37 English words against Spanish audio where the right language
        /// returned 50. A ratio of 1.35 is not a detection. Confidence
        /// separates the two cleanly because the engine knows it is guessing.
        public let confidence: Double

        /// Words weighted by how sure the engine was of them.
        public var weighted: Double { Double(words) * confidence }

        public init(locale: String, words: Int, confidence: Double) {
            self.locale = locale
            self.words = words
            self.confidence = confidence
        }
    }

    /// How the answer was reached, recorded on the outcome.
    ///
    /// Provenance keeps this honest. A locale chosen from the model's own
    /// language head and one inferred from word counts are different kinds of
    /// claim, and a transcript's provenance should not flatten them.
    public enum Method: String, Sendable, Codable {
        /// The engine's own language identifier.
        case modelLanguageHead
        /// Transcribing a sample in each candidate and comparing word counts.
        case transcriptionProbe
        /// Fewer than two candidates, or too little speech to sample.
        case notAttempted
    }

    /// How sure the model must be before its answer is taken.
    ///
    /// 0.90, set from measurement rather than taste. On the corpus the head
    /// returns 0.999 for single-language audio — 0.9994 for English and 0.9987
    /// for Spanish, against runner-ups of 0.0000 and 0.0006 — so a threshold
    /// anywhere below 0.99 accepts those with room to spare.
    ///
    /// What 0.90 buys is the behaviour at the other end. A recording that is
    /// two-thirds Spanish with an English passage in the middle scores 0.9814
    /// and is accepted, which is the case that matters: it is the shape of the
    /// field report that started this work, and the old probe declined it. A
    /// recording that changes language halfway scores 0.81 to 0.85 and is
    /// declined, which is right — there is no single correct language for it,
    /// and the user's own setting is a better answer than a coin toss weighted
    /// by where the sample happened to land.
    public static let minimumLanguageProbability = 0.90

    public struct Outcome: Sendable {
        /// The chosen locale, or `nil` when no candidate was convincing.
        public let locale: String?
        /// Every candidate's score, for the provenance and for explaining the
        /// choice to someone who disagrees with it. Empty when the model
        /// answered directly and nothing was transcribed.
        public let scores: [Score]
        public let method: Method
        /// The model's own probabilities, when it had any.
        public let likelihoods: [LanguageLikelihood]

        public init(locale: String?, scores: [Score],
                    method: Method = .transcriptionProbe,
                    likelihoods: [LanguageLikelihood] = []) {
            self.locale = locale
            self.scores = scores
            self.method = method
            self.likelihoods = likelihoods
        }
    }

    /// How much audio to sample.
    ///
    /// Long enough that a sentence or two lands inside it, short enough that
    /// probing several languages stays cheap.
    public static let sampleDuration = MediaTime.seconds(20)

    /// The winner must beat the runner-up by this factor.
    ///
    /// Two languages that score within a factor of three of each other are not
    /// a detection, they are a coin toss — and quietly picking one would be
    /// worse than leaving the user's own setting alone. In practice a correct
    /// language outscores a wrong one by an order of magnitude or more.
    public static let decisiveMargin = 3.0

    /// Fewest words a winning candidate must produce.
    public static let minimumWords = 8

    /// Picks the locale that actually yields words.
    ///
    /// - Parameters:
    ///   - candidates: Locales to try, one per language. Probing nine English
    ///     variants would cost nine times as much to learn the same thing.
    ///   - makeEngine: Builds an engine. Called once when the engine reports
    ///     `localeSelectedPerCall`, and once per candidate when it does not.
    ///     The old contract here was a fresh engine per candidate on the
    ///     reasoning that `prepare(locale:)` is stateful — true of Apple's
    ///     engine and not of Whisper, where the locale is an argument to
    ///     `transcribe`. Asking the engine is cheaper than assuming the
    ///     stricter case for both.
    /// - Returns: The decision and every score behind it. A candidate that
    ///   throws — an uninstalled model, an unsupported locale — scores zero
    ///   rather than failing the probe, since the point is to find one that
    ///   works.
    public static func detect(
        in canonicalFile: URL,
        speech: [TimeRange],
        candidates: [String],
        options: TranscriptionOptions,
        sampleRate: Int = CanonicalFormat.sampleRate,
        makeEngine: @Sendable () -> any TranscriptionEngine
    ) async -> Outcome {
        guard candidates.count > 1, let sample = sampleRange(from: speech, sampleRate: sampleRate)
        else {
            return Outcome(locale: candidates.first, scores: [], method: .notAttempted)
        }

        // One engine is built up front either way, and it is asked whether it
        // can be reused across locales. Whisper can: its language comes from
        // `options.locale` on each `transcribe` call, and `prepare` only
        // validates and loads weights. Apple's cannot, because its transcriber
        // is built around a locale.
        //
        // This matters more than it reads. Probing used to build a fresh engine
        // per candidate, which loads the model once per language — the Android
        // session saw the Whisper model loaded three times inside a single
        // ten-second job and could not account for it. Two of those three were
        // this function. At `ggml-small`'s 487 MB that is about a gigabyte of
        // weights loaded to answer a question that needs one copy.
        let first = makeEngine()

        // Ask the model before inferring. Whisper's weights carry a language
        // head that answers from one encoder pass with no decoding, which is
        // both cheaper than the probe below — two full transcriptions of the
        // sample — and a different kind of answer: a probability rather than a
        // guess from how many words came out.
        //
        // Measured, which is why this is first rather than a fallback: the
        // head returns 0.999 for single-language audio where the probe's
        // margin on the same samples was 1.06 to 1.86 against a required 3.0,
        // so the probe declined every case including pure English.
        let reusable = await first.capabilities().localeSelectedPerCall

        // Prepared once, here, rather than inside both the identification
        // below and the loop after it. The counting tests caught that: asking
        // the language head and then probing prepared the same engine twice.
        // Harmless for Whisper, whose `prepare` returns early when the context
        // exists, and wasteful for anything whose does not — and a wasted
        // model load is 487 MB with ggml-small.
        var prepared = (try? await first.prepare(locale: candidates[0])) != nil

        if prepared,
           let native = try? await identify(sample, in: canonicalFile,
                                            using: first, candidates: candidates),
           native.locale != nil {
            await first.release()
            return native
        }

        var scores: [Score] = []

        for (index, locale) in candidates.enumerated() {
            let engine: any TranscriptionEngine
            if reusable {
                engine = first
            } else if index == 0 {
                // The first candidate uses the engine prepared above, for the
                // locale it was prepared with. Clearing `prepared` here as
                // well would prepare it a second time.
                engine = first
            } else {
                engine = makeEngine()
                prepared = false
            }

            var probeOptions = options
            probeOptions.locale = locale
            // One chunk, so concurrency is irrelevant and a lower value keeps
            // the probe from contending with nothing.
            probeOptions.concurrency = 1

            var words = 0
            var confidence = 0.0
            do {
                if !prepared {
                    try await engine.prepare(locale: locale)
                    prepared = true
                }
                let segments = try await engine.transcribe(sample, in: canonicalFile,
                                                           options: probeOptions)
                let text = segments.map(\.text).joined(separator: " ")
                words = TextTokenizer.tokens(text).count
                let reported = segments.compactMap(\.confidence).map(Double.init)
                confidence = reported.isEmpty
                    ? 0
                    : reported.reduce(0, +) / Double(reported.count)
            } catch {
                words = 0
                confidence = 0
            }
            if !reusable { await engine.release() }
            scores.append(Score(locale: locale, words: words, confidence: confidence))
        }

        if reusable { await first.release() }
        return Outcome(locale: decide(scores), scores: scores)
    }

    /// Asks the engine's own language identifier, if it has one.
    ///
    /// Returns an outcome whose `locale` is `nil` when the engine cannot tell
    /// or is not sure enough, so the caller falls through to probing.
    ///
    /// The answer is narrowed to the candidates the caller offered. The model
    /// names languages and the project uses locales, so a top answer of
    /// Spanish selects whichever Spanish locale was asked about — Whisper does
    /// not distinguish es-ES from es-MX and should not be made to appear to.
    /// - Parameter engine: already prepared. Which locale it was prepared for
    ///   does not matter: the language head is a property of the model, not of
    ///   the locale.
    static func identify(
        _ sample: SampleRange,
        in canonicalFile: URL,
        using engine: any TranscriptionEngine,
        candidates: [String]
    ) async throws -> Outcome {
        let likelihoods = try await engine.identifyLanguage(sample, in: canonicalFile)
        guard let top = likelihoods.first else {
            return Outcome(locale: nil, scores: [], method: .transcriptionProbe)
        }
        guard top.probability >= minimumLanguageProbability else {
            return Outcome(locale: nil, scores: [], method: .modelLanguageHead,
                           likelihoods: likelihoods)
        }
        let language = top.locale.split(separator: "-").first.map(String.init)?.lowercased()
        let chosen = candidates.first {
            $0.split(separator: "-").first.map(String.init)?.lowercased() == language
        }
        // A confident answer in a language nobody asked about is not an answer
        // to the question, so it falls through rather than being forced.
        return Outcome(locale: chosen, scores: [], method: .modelLanguageHead,
                       likelihoods: likelihoods)
    }

    /// Picks a winner, or `nil` when the scores do not justify one.
    ///
    /// Separated from the probing so the rule can be tested without audio or
    /// an engine, which is the half most likely to be got wrong.
    public static func decide(_ scores: [Score]) -> String? {
        let ranked = scores.sorted { $0.weighted > $1.weighted }
        guard let best = ranked.first, best.words >= minimumWords, best.weighted > 0 else {
            return nil
        }
        let runnerUp = ranked.dropFirst().first?.weighted ?? 0
        guard best.weighted >= Swift.max(runnerUp, 0.0001) * decisiveMargin else { return nil }
        return best.locale
    }

    /// A span of actual speech to probe.
    ///
    /// Taken from the middle rather than the start: recordings open with room
    /// tone, throat-clearing and "testing, testing", none of which identifies a
    /// language.
    static func sampleRange(from speech: [TimeRange], sampleRate: Int) -> SampleRange? {
        guard !speech.isEmpty else { return nil }
        let total = speech.reduce(MediaTime.zero) { $0 + $1.duration }
        guard total > MediaTime.seconds(1) else { return nil }

        let target = MediaTime.min(sampleDuration, total)
        // Walk to the midpoint of the speech, then take the sample from there.
        var remaining = (total - target) * 0.5
        var start = speech[0].start
        for region in speech {
            if remaining <= region.duration {
                start = region.start + remaining
                break
            }
            remaining = remaining - region.duration
        }

        let startSample = start.samples(at: sampleRate)
        let count = target.samples(at: sampleRate)
        return SampleRange(start: Swift.max(0, startSample), count: Swift.max(0, count))
    }
}
