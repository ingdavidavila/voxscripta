import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaTranscription

/// How many engines the language probe builds.
///
/// Worth a test of its own because the cost is invisible locally and severe on
/// a phone. The probe used to build a fresh engine per candidate language, so
/// detecting between English and Spanish loaded the Whisper weights twice
/// before the real transcription loaded them a third time. The Android session
/// saw exactly that — three `loading model` sequences inside one ten-second
/// job — and could not account for it. At `ggml-small`'s 487 MB those two
/// extra loads are most of a gigabyte spent answering a question that needs
/// one copy of the model.
///
/// Counting construction rather than measuring memory keeps this portable and
/// instant: no model, no audio, runs anywhere.
@Suite("Language probe engine reuse")
struct LanguageProbeReuseTests {

    /// Counts how often it is built and prepared, and answers either way about
    /// whether it can be reused across locales.
    private actor CountingEngine: TranscriptionEngine {
        let identifier = EngineID.whisper
        nonisolated let modelIdentity = "counting|0"
        private let perCallLocale: Bool
        private let counter: Counter

        init(perCallLocale: Bool, counter: Counter) {
            self.perCallLocale = perCallLocale
            self.counter = counter
        }

        func capabilities() async -> EngineCapabilities {
            EngineCapabilities(supportsWordTimestamps: true,
                               supportedLocales: ["en-US", "es-ES"],
                               localeSelectedPerCall: perCallLocale)
        }

        func prepare(locale: String) async throws { await counter.prepared() }
        func release() async { await counter.released() }

        func transcribe(_ range: SampleRange, in canonicalFile: URL,
                        options: TranscriptionOptions) async throws -> [TranscriptSegment] {
            await counter.transcribed(options.locale)
            // Spanish "wins" with more words, so the probe has a decision to
            // make and the reuse path is exercised to the end rather than
            // short-circuiting.
            let words = options.locale.hasPrefix("es") ? 40 : 6
            return [TranscriptSegment(
                originalStart: .zero,
                originalEnd: .seconds(20),
                text: (0..<words).map { "w\($0)" }.joined(separator: " "),
                confidence: 0.9)]
        }
    }

    private struct Tally: Sendable {
        var built = 0
        var prepares = 0
        var releases = 0
        var locales: [String] = []
    }

    private actor Counter {
        private var tally = Tally()
        func build() { tally.built += 1 }
        func prepared() { tally.prepares += 1 }
        func released() { tally.releases += 1 }
        func transcribed(_ locale: String) { tally.locales.append(locale) }
        /// Read once into a value: `#expect` compares inside a non-async
        /// autoclosure, so an actor property cannot be awaited there.
        func snapshot() -> Tally { tally }
    }

    private func probe(perCallLocale: Bool) async -> (Tally, LanguageProbe.Outcome) {
        let counter = Counter()
        let tmp = URL(filePath: NSTemporaryDirectory()).appending(path: "probe.f32")
        let outcome = await LanguageProbe.detect(
            in: tmp,
            speech: [TimeRange(start: .zero, end: .seconds(60))],
            candidates: ["en-US", "es-ES"],
            options: .default,
            makeEngine: {
                let engine = CountingEngine(perCallLocale: perCallLocale, counter: counter)
                Task { await counter.build() }
                return engine
            })
        // The build counter is incremented from a detached task, so give those
        // a turn before reading it. Counted this way rather than synchronously
        // because `makeEngine` is not async.
        try? await Task.sleep(for: .milliseconds(50))
        return (await counter.snapshot(), outcome)
    }

    @Test("An engine that chooses its locale per call is built once")
    func reusableEngineIsBuiltOnce() async {
        let (tally, outcome) = await probe(perCallLocale: true)
        #expect(tally.built == 1, "built \(tally.built) engines for 2 candidates")
        #expect(tally.prepares == 1, "the model should load once, loaded \(tally.prepares)")
        #expect(tally.releases == 1, "and be released once")
        // Both candidates must still actually be probed — building one engine
        // is only correct if it answered both questions.
        #expect(tally.locales == ["en-US", "es-ES"])
        #expect(outcome.locale == "es-ES", "Spanish produced far more words")
    }

    @Test("An engine bound to a locale is still built once per candidate")
    func nonReusableEngineIsBuiltPerCandidate() async {
        // The conservative path has to keep working unchanged: Apple's engine
        // builds its transcriber around a locale and cannot be reused, and the
        // default for the capability is false so any engine that has not
        // thought about it gets this path.
        let (tally, outcome) = await probe(perCallLocale: false)
        #expect(tally.built == 2, "one engine per candidate, built \(tally.built)")
        #expect(tally.prepares == 2)
        #expect(tally.releases == 2, "each must be released")
        #expect(tally.locales == ["en-US", "es-ES"])
        #expect(outcome.locale == "es-ES", "the decision must not depend on reuse")
    }

    @Test("Whisper reports that it chooses its locale per call")
    func whisperDeclaresPerCallLocale() async {
        // The capability is only useful if the engine that benefits sets it.
        let caps = await WhisperEngine().capabilities()
        #expect(caps.localeSelectedPerCall,
                "Whisper applies options.locale inside transcribe, so one context serves both")
    }

    @Test("The default is the conservative answer")
    func defaultIsFalse() {
        // A new engine that does not consider this must get the safe path, not
        // silently share a context it cannot share.
        let caps = EngineCapabilities(supportsWordTimestamps: false, supportedLocales: [])
        #expect(caps.localeSelectedPerCall == false)
    }
}
