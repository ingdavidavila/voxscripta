#if canImport(AVFoundation)
import Testing
import Foundation
import AVFoundation
import VoxScriptaCore
import VoxScriptaDSP
import VoxScriptaBench
import VoxScriptaTestSupport
@testable import VoxScriptaTranscription

/// What a Whisper context actually costs to hold.
///
/// The question this answers is the one that has to be settled before anyone
/// proposes a worker pool: `ggml-base.bin` is 141 MB on disk, and on-disk size
/// is not runtime footprint. A pool of four contexts is only viable if four
/// contexts fit, and nobody has measured one.
///
/// Off by default — it loads a model and runs real inference, which is slow
/// and needs weights the machine may not have. Run it with:
///
///     VOXSCRIPTA_WHISPER_MEMORY=1 swift test --filter WhisperMemoryMeasurement
///
/// The numbers are the point; there are no accuracy assertions here. The only
/// thing asserted is that the measurement happened at all, because a
/// benchmark that silently measures nothing is worse than none.
@Suite("Whisper memory", .serialized)
struct WhisperMemoryMeasurement {

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["VOXSCRIPTA_WHISPER_MEMORY"] == "1"
            && FileManager.default.fileExists(atPath: WhisperEngine.defaultModelURL().path)
    }

    @Test("Resident cost of one context, and of several at once",
          .enabled(if: WhisperMemoryMeasurement.enabled,
                   "set VOXSCRIPTA_WHISPER_MEMORY=1 and fetch the model"))
    func contextCost() async throws {
        // Real speech rather than a tone: a synthetic sine decodes to nothing
        // and the decoder exits early, which would measure model loading alone
        // rather than loading plus inference. TempDirectory is noncopyable, so
        // it stays a local here rather than being returned from a helper.
        let tmp = try TempDirectory()
        let samples = try await SpeechCorpus.render(SpeechCorpus.standard)
        let wav = tmp.url.appending(path: "speech.wav")
        try AudioFileWriter.write(samples: samples, to: wav, format: .wav,
                                  sampleRate: CanonicalFormat.sampleRate)
        let canonical = tmp.url.appending(path: "canonical.f32")
        let written = try await CanonicalDecoder().decode(url: wav, to: canonical) { _ in }
        let range = SampleRange(start: 0, count: written)
        print("  audio: \(String(format: "%.1f", Double(written) / Double(CanonicalFormat.sampleRate))) s")

        let baseline = try MemoryFootprint.current()
        print("""

        WHISPER MEMORY · \(WhisperEngine.defaultModelURL().lastPathComponent)
          baseline footprint: \(Self.mb(baseline))
        """)

        var measured: [(workers: Int, peak: Int64, elapsed: Double)] = []

        for workers in [1, 2, 4] {
            // Fresh engines each round, so one round's contexts are released
            // before the next allocates. Otherwise this measures accumulation
            // rather than concurrency.
            let engines = (0..<workers).map { _ in WhisperEngine() }
            for engine in engines { try await engine.prepare(locale: "en-US") }

            let started = ContinuousClock.now
            let (_, peak) = try await MemoryFootprint.peak {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for engine in engines {
                        group.addTask {
                            var options = TranscriptionOptions.default
                            options.locale = "en-US"
                            _ = try await engine.transcribe(range, in: canonical, options: options)
                        }
                    }
                    try await group.waitForAll()
                }
            }
            let elapsed = (ContinuousClock.now - started).elapsedSeconds
            for engine in engines { await engine.release() }

            measured.append((workers, peak, elapsed))
            print("""
              \(workers) context(s): peak \(Self.mb(peak)), \
            over baseline \(Self.mb(peak - baseline)), \
            \(String(format: "%.2f", elapsed)) s for \(workers)× the same audio
            """)
        }

        // Per-context cost, inferred from the difference rather than assumed
        // from the file size.
        if let one = measured.first(where: { $0.workers == 1 }),
           let two = measured.first(where: { $0.workers == 2 }) {
            print("""
              marginal cost of a second context: \(Self.mb(two.peak - one.peak))
            """)
        }

        #expect(measured.count == 3, "every worker count must have been measured")
        #expect(measured.allSatisfy { $0.peak > 0 }, "a peak of zero means nothing was sampled")
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
#endif
