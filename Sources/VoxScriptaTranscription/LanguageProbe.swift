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

    public struct Outcome: Sendable {
        /// The chosen locale, or `nil` when no candidate was convincing.
        public let locale: String?
        /// Every candidate's score, for the provenance and for explaining the
        /// choice to someone who disagrees with it.
        public let scores: [Score]

        public init(locale: String?, scores: [Score]) {
            self.locale = locale
            self.scores = scores
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
            return Outcome(locale: candidates.first, scores: [])
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
        let reusable = await first.capabilities().localeSelectedPerCall

        var scores: [Score] = []
        var prepared = false

        for (index, locale) in candidates.enumerated() {
            let engine: any TranscriptionEngine
            if reusable {
                engine = first
            } else {
                engine = index == 0 ? first : makeEngine()
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
