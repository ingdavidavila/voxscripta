#if canImport(Speech)
import Testing
import Foundation
import AVFoundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaBench
import VoxScriptaTestSupport
@testable import VoxScriptaTranscription

/// What chunking costs.
///
/// The pipeline cuts a recording into chunks, transcribes them separately and
/// stitches the results. That seam has never been measured. There is a test
/// asserting chunked and single-chunk output are byte-identical, but it runs on
/// audio short enough to produce one chunk either way, so it proves the
/// plumbing rather than the merge.
///
/// The measurement is a subtraction and needs no word-level alignment: the same
/// audio transcribed whole, and transcribed through the real planner, scheduler
/// and merger. Any difference is what the seam cost, because nothing else
/// differs.
///
/// The real stages on purpose. Hand-cutting the audio at invented boundaries
/// would measure a chunking scheme that does not ship — the planner's choice of
/// where to cut is most of what is under test, since it is what decides whether
/// a cut lands inside a word.
@Suite("Merge cost", .serialized)
struct MergeCostMeasurement {

    static var hasSpanishVoice: Bool { AVSpeechSynthesisVoice(language: "es-ES") != nil }
    static var requested: Bool {
        ProcessInfo.processInfo.environment["VOXSCRIPTA_CORPUS"] == "1"
    }
    static var whisperModelAvailable: Bool {
        FileManager.default.fileExists(atPath: WhisperEngine.defaultModelURL().path)
    }

    private let parameterHash = "merge-cost-measurement"

    /// One `transcribe` call over the whole file. The baseline.
    private func whole(_ canonical: URL, _ samples: Int64, _ locale: String,
                       engine: any TranscriptionEngine) async throws -> String {
        var options = TranscriptionOptions.default
        options.locale = locale
        let segments = try await engine.transcribe(
            SampleRange(start: 0, count: samples), in: canonical, options: options)
        return segments.map(\.text).joined(separator: " ")
    }

    /// The shipping path: analyze, detect silence, plan, schedule, merge.
    private func chunked(_ canonical: URL, _ locale: String,
                         engine: any TranscriptionEngine) async throws -> (String, Int) {
        let features = try await FrameAnalyzer().analyze(
            canonicalFile: canonical, geometry: .default) { _ in }
        let silenceMap = try SilenceDetector().detect(
            features: features, parameters: .default,
            sourceDuration: features.duration, parameterHash: parameterHash)
        let plan = try ChunkPlanner().plan(
            silenceMap: silenceMap, parameters: .default, parameterHash: parameterHash)

        var options = TranscriptionOptions.default
        options.locale = locale
        let outcome = try await ChunkScheduler().run(
            plan: plan, canonicalFile: canonical, engine: engine, options: options)

        do {
            let transcript = try TranscriptMerger().merge(
                chunks: outcome.transcripts, plan: plan, silenceMap: silenceMap,
                provenance: Provenance(
                    engineID: engine.identifier,
                    silenceParameterHash: parameterHash,
                    chunkParameterHash: parameterHash,
                    concurrency: options.concurrency))
            return (transcript.plainText(), plan.chunks.count)
        } catch {
            // Report the seam geometry rather than just the thrown message.
            // Whether this is the overlap dedupe failing or the engine's
            // timestamps jittering across a boundary are different bugs with
            // different fixes, and the thrown error distinguishes neither.
            print("\n✘ merge failed: \(error)")
            print("  plan: \(plan.chunks.count) chunks")
            for spec in plan.chunks.sorted(by: { $0.sequence < $1.sequence }) {
                let chunk = outcome.transcripts.first { $0.chunkID == spec.id }
                let first = chunk?.segments.min { $0.originalStart < $1.originalStart }
                let last = chunk?.segments.max { $0.originalEnd < $1.originalEnd }
                print(String(format: "   #%d plan %.2f…%.2f  overlapLead %.2f  segments %.2f…%.2f (%d)",
                             spec.sequence,
                             spec.originalRange.start.seconds, spec.originalRange.end.seconds,
                             spec.overlapLead.seconds,
                             first?.originalStart.seconds ?? -1,
                             last?.originalEnd.seconds ?? -1,
                             chunk?.segments.count ?? 0))
            }
            throw error
        }
    }

    @Test("Merge cost on the long cases, Whisper",
          .enabled(if: MergeCostMeasurement.requested
                       && MergeCostMeasurement.hasSpanishVoice
                       && MergeCostMeasurement.whisperModelAvailable,
                   "needs VOXSCRIPTA_CORPUS=1 and a fetched Whisper model"))
    func mergeCostOnWhisper() async throws {
        let tmp = try TempDirectory()
        let engine = WhisperEngine()
        let runner = CorpusRunner(engineID: "whisper", modelIdentity: engine.modelIdentity)
        try await engine.prepare(locale: "en-US")

        var rows: [CorpusMeasurement] = []
        var chunkCounts: [String: Int] = [:]
        // Whatever happens below, the context is freed before this function
        // returns. Letting a throw skip it leaves whisper_free unrun, and
        // ggml then trips GGML_ASSERT in a static destructor at process exit,
        // which buries the real failure under a signal.
        var failure: (any Error)?

        for testCase in TranscriptionCorpus.long {
            let locale = testCase.segments.first?.voiceLanguage ?? "en-US"
            let rendered: CorpusRunner.Rendered
            do {
                rendered = try await runner.render(testCase, into: tmp.url)
            } catch {
                print("⚠︎ skipped \(testCase.name): \(error)")
                continue
            }

            var started = Date()
            let wholeText: String
            do {
                wholeText = try await whole(rendered.canonical, rendered.sampleCount,
                                            locale, engine: engine)
            } catch { failure = error; break }
            rows.append(runner.score(testCase, hypothesis: wholeText, path: "whole",
                                     audioSeconds: rendered.seconds,
                                     wallSeconds: Date().timeIntervalSince(started)))

            started = Date()
            let chunkedText: String
            let chunks: Int
            do {
                (chunkedText, chunks) = try await chunked(rendered.canonical, locale,
                                                          engine: engine)
            } catch { failure = error; break }
            rows.append(runner.score(testCase, hypothesis: chunkedText, path: "chunked",
                                     audioSeconds: rendered.seconds,
                                     wallSeconds: Date().timeIntervalSince(started)))
            chunkCounts[testCase.name] = chunks
        }
        await engine.release()
        if let failure {
            // Surfaced after the release, so the message survives.
            Issue.record("the chunked path failed: \(failure)")
            return
        }

        let report = CorpusReport(rows: rows)
        print("\nMERGE COST · whisper · \(report.hardware)")
        print("model: \(rows.first?.modelIdentity ?? "unknown")\n")
        print(report.table)

        print("audio length and chunks planned:")
        for (name, count) in chunkCounts.sorted(by: { $0.key < $1.key }) {
            let seconds = rows.first { $0.caseName == name }?.audioSeconds ?? 0
            print(String(format: "  %@ %5.1f min → %d chunks",
                         name.padding(toLength: 24, withPad: " ", startingAt: 0),
                         seconds / 60, count))
        }

        let deltas = report.mergeDeltas()
        print("\nmerge delta (chunked minus whole, in word error rate points):")
        for (name, wholeRate, chunkedRate, delta) in deltas {
            print(String(format: "  %@ %6.2f%% → %6.2f%%   %+.2f points",
                         name.padding(toLength: 24, withPad: " ", startingAt: 0),
                         wholeRate * 100, chunkedRate * 100, delta * 100))
        }

        #expect(!deltas.isEmpty, "nothing was measured both ways")

        // A case that planned one chunk took the same path twice, so its delta
        // is necessarily zero and says nothing about merging. The first run of
        // this measurement did exactly that — three cases, three deltas of
        // +0.00 — and a warning was not enough, because a passing test that
        // printed zeros reads like a result. So it fails instead: a
        // measurement that measured nothing is not a pass.
        let single = chunkCounts.filter { $0.value < 2 }.keys.sorted()
        #expect(single.isEmpty,
                "these cases planned one chunk, so nothing was merged and their deltas are meaningless: \(single.joined(separator: ", "))")

        let seams = chunkCounts.values.reduce(0) { $0 + max(0, $1 - 1) }
        print("\nseams exercised: \(seams)")
        #expect(seams >= 3, "only \(seams) seams across the whole run")
    }
}
#endif
