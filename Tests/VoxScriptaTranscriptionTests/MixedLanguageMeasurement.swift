#if canImport(Speech)
import Testing
import Foundation
import AVFoundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaTestSupport
@testable import VoxScriptaTranscription

/// What the language probe does with a recording that changes language.
///
/// The brief asks for this behaviour to be documented rather than fixed, and
/// that is the right order: there is no single correct answer for a bilingual
/// recording, so "what should it do" is a product question and "what does it
/// do" is a prerequisite for asking it.
///
/// The mechanism that decides the answer is worth stating before the numbers.
/// `LanguageProbe` samples twenty seconds **from the midpoint of the speech**
/// and transcribes that sample in each candidate language, taking the one whose
/// confidence-weighted word count beats the runner-up by a factor of three. So
/// for a recording whose language changes halfway, the sample lands exactly on
/// the seam; and for one that is mostly Spanish with an English passage in the
/// middle, it lands on the English.
///
/// That is a prediction, which is why it is measured rather than asserted.
@Suite("Mixed language", .serialized)
struct MixedLanguageMeasurement {

    static var hasSpanishVoice: Bool { AVSpeechSynthesisVoice(language: "es-ES") != nil }
    static var requested: Bool {
        ProcessInfo.processInfo.environment["VOXSCRIPTA_CORPUS"] == "1"
    }
    static var whisperModelAvailable: Bool {
        FileManager.default.fileExists(atPath: WhisperEngine.defaultModelURL().path)
    }

    private func speechRegions(in canonical: URL) async throws -> ([TimeRange], MediaTime) {
        let features = try await FrameAnalyzer().analyze(
            canonicalFile: canonical, geometry: .default) { _ in }
        let map = try SilenceDetector().detect(
            features: features, parameters: .default,
            sourceDuration: features.duration, parameterHash: "mixed-language")
        return (map.speechRegions.map(\.range), features.duration)
    }

    // The run-wide conditions are a trait, not a #require: #require *fails* a
    // test when its condition is false, which is the opposite of skipping, and
    // a measurement that could not run must not read as a regression. The
    // per-engine model check cannot be a trait because a trait cannot see the
    // argument, so it returns early and says so.
    @Test("What the probe does with mixed-language audio",
          .enabled(if: MixedLanguageMeasurement.requested
                       && MixedLanguageMeasurement.hasSpanishVoice,
                   "needs VOXSCRIPTA_CORPUS=1 and a Spanish voice"),
          arguments: ["whisper", "apple"])
    func probeOnMixedAudio(engineName: String) async throws {
        if engineName == "whisper", !Self.whisperModelAvailable {
            print("skipping whisper: no model fetched")
            return
        }
        // if/else rather than a ternary: two closure literals in a ternary
        // defeat the type checker, which reports a compiler bug instead of an
        // error.
        let makeEngine: @Sendable () -> any TranscriptionEngine
        if engineName == "whisper" {
            makeEngine = { WhisperEngine() }
        } else {
            makeEngine = { AppleSpeechEngine() }
        }

        let tmp = try TempDirectory()
        let runner = CorpusRunner(engineID: engineName, modelIdentity: "")

        // The two single-language cases are controls. Without them a weak
        // result on mixed audio says nothing — it could just as easily be the
        // probe being weak on everything.
        let cases = (TranscriptionCorpus.conditioned.filter {
            $0.name == "en_clean" || $0.name == "es_clean"
        }) + TranscriptionCorpus.mixedLanguage

        print("\nMIXED LANGUAGE · \(engineName) · \(CorpusReport.describeHardware())")
        print("probe: \(LanguageProbe.sampleDuration.seconds)s sample from the midpoint, "
            + "margin \(LanguageProbe.decisiveMargin)x, minimum \(LanguageProbe.minimumWords) words\n")

        var undetermined: [String] = []
        var answers: [String: String] = [:]
        var nativeAnswers: [String: [LanguageLikelihood]] = [:]

        for testCase in cases {
            let rendered: CorpusRunner.Rendered
            do {
                rendered = try await runner.render(testCase, into: tmp.url)
            } catch {
                print("⚠︎ skipped \(testCase.name): \(error)")
                continue
            }

            let (regions, duration) = try await speechRegions(in: rendered.canonical)
            let sample = LanguageProbe.sampleRange(from: regions,
                                                   sampleRate: CanonicalFormat.sampleRate)

            let outcome = await LanguageProbe.detect(
                in: rendered.canonical, speech: regions,
                candidates: ["en-US", "es-ES"],
                options: .default,
                makeEngine: makeEngine)

            // The model's own answer, beside the probe's inference, on the
            // identical sample — so the two are comparable rather than merely
            // both present.
            if engineName == "whisper", let sample {
                let engine = WhisperEngine()
                try await engine.prepare(locale: "en-US")
                let native = try await engine.identifyLanguage(sample, in: rendered.canonical)
                await engine.release()
                let line = native.prefix(3).map {
                    String(format: "%@ %.3f", $0.locale, $0.probability)
                }.joined(separator: "  ")
                nativeAnswers[testCase.name] = native
                print("  native: \(line)")
            }

            let sampleStart = sample.map {
                Double($0.start) / Double(CanonicalFormat.sampleRate)
            } ?? -1
            let ordered = outcome.scores.sorted { $0.weighted > $1.weighted }
            let margin = ordered.count >= 2 && ordered[1].weighted > 0
                ? ordered[0].weighted / ordered[1].weighted
                : Double.infinity

            print("\(testCase.name)")
            print(String(format: "  audio %.0fs, speech %.0fs in %d regions, "
                                + "sample from %.0fs",
                         rendered.seconds, duration.seconds, regions.count, sampleStart))
            for score in ordered {
                print(String(format: "  %@  %4d words  confidence %.2f  weighted %7.1f",
                             score.locale, score.words, score.confidence, score.weighted))
            }
            print(String(format: "  margin %.2fx against a required %.1fx  →  %@  [%@]",
                         margin, LanguageProbe.decisiveMargin,
                         outcome.locale ?? "UNDETERMINED (falls back to the user's setting)",
                         outcome.method.rawValue))
            print("  purpose: \(testCase.purpose)\n")

            answers[testCase.name] = outcome.locale ?? "undetermined"
            if outcome.locale == nil { undetermined.append(testCase.name) }
        }

        print("summary:")
        for (name, answer) in answers.sorted(by: { $0.key < $1.key }) {
            print("  \(name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(answer)")
        }

        // The controls are the measurement here rather than a precondition.
        // An engine on which the probe cannot even identify single-language
        // audio is the finding, so it is printed and not thrown.
        let controlsDetected = answers["en_clean"] == "en-US"
            && answers["es_clean"] == "es-ES"
        print(controlsDetected
            ? "\ncontrols: both detected — the probe works on \(engineName)"
            : "\ncontrols: NOT detected — the probe cannot identify even "
              + "single-language audio on \(engineName)")
        print("undetermined: \(undetermined.count) of \(answers.count)")

        if !nativeAnswers.isEmpty {
            print("\nthe model's own language head, same samples:")
            for (name, scores) in nativeAnswers.sorted(by: { $0.key < $1.key }) {
                let top = scores.first
                let runnerUp = scores.first { $0.locale.prefix(2) != top?.locale.prefix(2) }
                let ratio = (runnerUp?.probability ?? 0) > 0
                    ? (top?.probability ?? 0) / (runnerUp?.probability ?? 1)
                    : Double.infinity
                print(String(format: "  %@ top %@ %.4f  next %@ %.4f  ratio %.0fx",
                             name.padding(toLength: 20, withPad: " ", startingAt: 0),
                             top?.locale ?? "-", top?.probability ?? 0,
                             runnerUp?.locale ?? "-", runnerUp?.probability ?? 0,
                             ratio))
            }
        }
        #expect(!answers.isEmpty, "nothing was measured")
    }
}
#endif
