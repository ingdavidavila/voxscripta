import Testing
import Foundation
import VoxVerbaCore
import VoxVerbaDSP
import VoxVerbaBench
import VoxVerbaTestSupport
@testable import VoxVerbaTranscription

/// End-to-end tests against the real on-device engine.
///
/// Serialized because they contend for the same system speech service, and slow
/// because they synthesize audio and run a model. They are the only tests that
/// touch the real engine; everything else uses `MockTranscriptionEngine`.
@Suite("Apple engine, end to end", .serialized)
struct AppleEngineEndToEndTests {

    /// Renders passages, decodes them, and runs the full transcription path.
    private func transcribe(
        _ passages: [SpeechPassage],
        concurrency: Int = 4,
        chunkSeconds: Double = 45
    ) async throws -> (text: String, transcript: Transcript, reference: String) {
        let tmp = try TempDirectory()
        let samples = try await SpeechCorpus.render(passages)
        let wav = tmp.url.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: samples, to: wav, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)

        let canonical = tmp.url.appending(path: "canonical.f32")
        let written = try await CanonicalDecoder().decode(url: wav, to: canonical) { _ in }
        let features = try await FrameAnalyzer().analyze(canonicalFile: canonical,
                                                         geometry: .default) { _ in }
        let duration = MediaTime(samples: written, sampleRate: CanonicalFormat.sampleRate)
        let map = try SilenceDetector().detect(features: features, parameters: .default,
                                               sourceDuration: duration, parameterHash: "e2e")
        var chunking = ChunkParameters.default
        chunking.maxDuration = .seconds(chunkSeconds)
        chunking.targetDuration = .seconds(chunkSeconds * 0.8)
        chunking.minDuration = .seconds(chunkSeconds * 0.4)
        let plan = try ChunkPlanner().plan(silenceMap: map, parameters: chunking, parameterHash: "e2e")

        var options = TranscriptionOptions.default
        options.concurrency = concurrency

        let engine = AppleSpeechEngine()
        try await engine.prepare(locale: "en-US")
        defer { Task { await engine.release() } }

        let outcome = try await ChunkScheduler().run(
            plan: plan, canonicalFile: canonical, engine: engine, options: options)
        let transcript = try TranscriptMerger().merge(
            chunks: outcome.transcripts, plan: plan, silenceMap: map,
            provenance: Provenance(engineID: engine.identifier, concurrency: concurrency))

        return (transcript.plainText(), transcript, SpeechCorpus.referenceText(for: passages))
    }

    @Test("Word error rate on synthesized speech stays under 15%")
    func wordErrorRate() async throws {
        let result = try await transcribe(SpeechCorpus.standard)
        let wer = WordErrorRate.measure(reference: result.reference, hypothesis: result.text)
        print("E2E \(wer)")

        // Measured around 4–6% on an M5 for this corpus. The bound is loose
        // because synthesized voices differ between machines and OS versions;
        // it is a regression guard, not a published accuracy claim.
        #expect(wer.rate < 0.15, "\(wer)")
    }

    @Test("Numbers and names survive transcription")
    func preservesEntities() async throws {
        // These are what the Phase 5 validator will have to protect, so it is
        // worth knowing the engine gets them right in the first place.
        let result = try await transcribe(Array(SpeechCorpus.standard.prefix(2)))
        let tokens = Set(TextTokenizer.comparableTokens(result.text))
        #expect(tokens.contains("500"))
        #expect(tokens.contains("312"))
        #expect(result.text.lowercased().contains("sarah"))
        #expect(result.text.lowercased().contains("chen"))
    }

    @Test("Every segment carries word timings on the original timeline")
    func wordTimings() async throws {
        let result = try await transcribe(Array(SpeechCorpus.standard.prefix(2)))
        let segments = result.transcript.segments.filter { !$0.words.isEmpty }
        #expect(!segments.isEmpty)

        for segment in segments {
            #expect(segment.words.allSatisfy { $0.originalStart <= $0.originalEnd })
            // Word times must lie inside their segment, or subtitle export drifts.
            #expect(segment.words.first!.originalStart >= segment.originalStart - .milliseconds(50))
            #expect(segment.words.last!.originalEnd <= segment.originalEnd + .milliseconds(50))
        }
        // Timings must advance monotonically across the whole transcript.
        let starts = segments.flatMap(\.words).map(\.originalStart)
        #expect(zip(starts, starts.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("A chunked run reconstructs one continuous transcript")
    func chunkingIsInvisible() async throws {
        // §15: the user never sees the chunk boundaries.
        let short = try await transcribe(SpeechCorpus.standard, chunkSeconds: 300)  // one chunk
        let chunked = try await transcribe(SpeechCorpus.standard, chunkSeconds: 20) // several

        let a = TextTokenizer.comparableTokens(short.text)
        let b = TextTokenizer.comparableTokens(chunked.text)
        let agreement = WordErrorRate.measure(reference: a, hypothesis: b)
        print("CHUNKED vs SINGLE: \(agreement)")

        // Chunking changes acoustic context at boundaries, so the two are not
        // required to be identical — only to agree closely.
        #expect(agreement.rate < 0.20, "chunking changed the transcript materially: \(agreement)")
    }

    @Test("Output is reproducible at a fixed concurrency")
    func deterministicAtFixedConcurrency() async throws {
        let passages = Array(SpeechCorpus.standard.prefix(3))
        let first = try await transcribe(passages, concurrency: 1)
        let second = try await transcribe(passages, concurrency: 1)
        #expect(first.text == second.text)
    }
}
