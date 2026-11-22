// Apple's recogniser and Apple's speech synthesizer, so the numbers exist only
// on the platform that produces them. Docs/PARITY.md records what that leaves
// uncovered elsewhere.
#if canImport(Speech)
import Testing
import Foundation
import AVFoundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaBench
import VoxScriptaTestSupport
@testable import VoxScriptaTranscription

/// What the corpus actually measures.
///
/// Up to now accuracy has been two numbers on clean audio — 5.6% English and
/// 7.0% Spanish — which says nothing about the recordings people actually
/// make. This runs the name-free passages through every acoustic condition in
/// both languages and prints the table, so a change to the pipeline has
/// something to be compared against.
///
/// ## What the first full run found
///
/// Measured on a 10-core, 24 GB Mac, macOS 26.6.2, Apple engine, 149–157 word
/// references. An error is about 0.67 points, so a difference under roughly
/// 1.3 points is a single word and is not signal.
///
/// | condition | English | Spanish |
/// |---|---|---|
/// | clean | 1.3% | 2.7% |
/// | quiet −18 dB | 1.3% | 2.0% |
/// | hum 12 dB SNR | 1.3% | 2.7% |
/// | music 10 dB SNR | 1.3% | 2.0% |
/// | machinery 6 dB SNR | 1.9% | 4.7% |
/// | hiss 12 dB SNR | 3.8% | 5.4% |
/// | pauses 3 s | 5.1% | 2.0% |
/// | abrupt ending | 1.3% | 2.7% |
/// | decaying final word | 1.3% | 2.7% |
///
/// Four things in that table are worth acting on.
///
/// **The published figures were not measuring hearing.** Clean audio scores
/// 1.3% and 2.7% here, against the 5.6% and 7.0% on the `standard` passages.
/// The difference is proper nouns: "northwind" was lost in all eighteen rows
/// of the earlier run, and "sara", "chen", "quizá" and "unidades" in all nine
/// of their language's rows. Four fixed errors on a seventy-word reference is
/// the whole of the 5.6%. The engine hears about four times better than the
/// number the engine was chosen on suggests — and names are about four times
/// worse. Both halves matter and neither was visible before.
///
/// **Broadband hiss is the worst condition for both languages**, roughly
/// tripling English error and doubling Spanish. Narrowband noise does not:
/// 60 Hz hum at the same signal-to-noise ratio costs nothing measurable in
/// either language. So signal-to-noise ratio alone does not predict damage,
/// and anything that decides whether a recording is usable needs to look at
/// the spectrum rather than the level.
///
/// **Spanish degrades about two and a half times harder than English under
/// machinery noise** — 2.7% to 4.7%, against 1.3% to 1.9%. On clean audio the
/// two languages are within 1.4 points; under noise the gap widens. That is
/// the shape of the complaint that started this work, and it means the Spanish
/// problem is a noise-robustness problem rather than a flat accuracy deficit.
///
/// **Three-second pauses are the worst English condition at 5.1%**, four times
/// clean, and the only condition producing deletions *and* insertions together
/// — two of each. Spanish is untouched by the same pauses. Insertions at pause
/// boundaries from a streaming recogniser point at premature finalization, and
/// this is the condition the chunk planner cuts on, so it bears directly on
/// merge quality.
///
/// Both tail conditions cost nothing in either language, which is the evidence
/// that the final-word truncation fix holds: an abrupt cut and a word fading
/// away over 1.2 s both score exactly as clean.
///
/// The full run is env-gated because it synthesizes and transcribes several
/// minutes of audio per condition; the smoke selection runs by default.
@Suite("Corpus measurement", .serialized)
struct CorpusMeasurementRun {

    static var hasSpanishVoice: Bool { AVSpeechSynthesisVoice(language: "es-ES") != nil }
    static var fullRunRequested: Bool {
        ProcessInfo.processInfo.environment["VOXSCRIPTA_CORPUS"] == "1"
    }

    /// Apple's engine behind the runner's closure.
    ///
    /// A fresh engine per case rather than one reused across the run. The
    /// per-call analyzer means concurrent use is safe, but a condition that
    /// left an engine in a bad state would otherwise contaminate every row
    /// after it, and a corpus whose rows depend on their order is not a corpus.
    private func appleTranscriber() -> CorpusRunner.Transcribe {
        { canonical, sampleCount, locale in
            let engine = AppleSpeechEngine()
            try await engine.prepare(locale: locale)
            var options = TranscriptionOptions.default
            options.locale = locale
            let segments = try await engine.transcribe(
                SampleRange(start: 0, count: sampleCount), in: canonical, options: options)
            await engine.release()
            return segments.map(\.text).joined(separator: " ")
        }
    }

    private func report(for cases: [TranscriptionCase]) async throws -> CorpusReport {
        let tmp = try TempDirectory()
        let runner = CorpusRunner(engineID: "apple",
                                  modelIdentity: AppleSpeechEngine().modelIdentity)

        let missing = CorpusRunner.missingVoices(for: cases)
        if !missing.isEmpty {
            // Said out loud rather than silently skipped: a run that covered
            // less than it was asked to has to say which rows are absent, or
            // the table reads as complete.
            print("⚠︎ no voice installed for \(missing.joined(separator: ", ")) "
                + "— those cases will be skipped")
        }

        return await runner.run(
            cases, in: tmp.url,
            onSkip: { name, error in print("⚠︎ skipped \(name): \(error)") },
            transcribe: appleTranscriber())
    }

    @Test("The smoke selection, measured",
          .enabled(if: CorpusMeasurementRun.hasSpanishVoice, "no Spanish voice installed"))
    func smoke() async throws {
        let report = try await report(for: TranscriptionCorpus.smoke)
        print("""

        CORPUS · smoke · apple engine
        \(report.hardware)

        \(report.table)
        aggregate word error rate: \
        \(String(format: "%.1f", report.aggregateWER * 100))% \
        over \(report.rows.count) cases
        """)
        #expect(!report.rows.isEmpty, "the smoke run produced no rows at all")
        // Deliberately loose. This is a regression bar, not a target: the point
        // is to notice a collapse, and a tight bound on synthesized speech
        // would fail on a machine with different voices installed.
        // Measured at 2.7% across the smoke selection. The bar is set well
        // above that because synthesized speech is not identical across
        // machines or OS versions — it catches a collapse, not drift.
        #expect(report.aggregateWER < 0.15,
                "smoke aggregate \(report.aggregateWER) is far above the measured 2.7%")
    }

    @Test("Every condition, both languages",
          .enabled(if: CorpusMeasurementRun.fullRunRequested
                       && CorpusMeasurementRun.hasSpanishVoice,
                   "set VOXSCRIPTA_CORPUS=1 to run the full corpus"))
    func everyCondition() async throws {
        let report = try await report(for: TranscriptionCorpus.conditioned)
        print("""

        CORPUS · every condition · apple engine
        \(report.hardware)

        \(report.table)
        """)

        // Per-condition aggregates, which is how the table is meant to be read:
        // a condition that costs one language and not the other is the finding,
        // and a single headline number hides exactly that.
        print("by condition:")
        for (slug, rows) in report.byCondition().sorted(by: { $0.key < $1.key }) {
            let sub = CorpusReport(rows: rows)
            let perLanguage = sub.byLanguage()
                .sorted { $0.key < $1.key }
                .map { "\($0.key.prefix(2)) \(String(format: "%.1f", CorpusReport(rows: $0.value).aggregateWER * 100))%" }
                .joined(separator: "  ")
            print("  \(slug.padding(toLength: 14, withPad: " ", startingAt: 0)) \(perLanguage)")
        }

        // Which words never survive, across every condition.
        //
        // The first full run of this corpus produced a table that barely moved
        // between conditions, and there are only two explanations: the
        // conditions are not reaching the engine, or the metric is saturated by
        // a fixed set of words that are wrong in every row. This distinguishes
        // them, which guessing would not.
        let missed = report.persistentlyMissedWords().filter { $0.rows > 1 }
        print("\nwords lost in more than one row (of \(report.rows.count)):")
        for (word, rows) in missed.prefix(20) {
            print("  \(rows)×  \(word)")
        }

        // And the per-row word counts, because an error is 1/N of the rate and
        // a short reference makes the rate too coarse to see a condition in.
        let words = Set(report.rows.map(\.wer.referenceWords)).sorted()
        print("\nreference lengths: \(words) words")

        #expect(!report.rows.isEmpty)
    }
}
#endif
