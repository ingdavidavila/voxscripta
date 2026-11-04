import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// Measures what a smaller polish model costs.
///
/// The question is install size: the bundled 1.5B model is 1.04 GB against
/// the 0.5B's 469 MB, and with whisper that is a 1.18 GB app versus 610 MB.
///
/// What it is **not** measuring is safety. `ValidationGauntlet` sits between
/// the model and the transcript and rejects a revision that changes meaning,
/// and it does that regardless of which model proposed it — the gauntlet
/// suites test the validator, not the model. So a weaker model cannot make
/// the app wrong. It can only make polish *do less*: propose worse revisions,
/// have more of them rejected, and leave more sentences as they were.
///
/// That is the number here. Acceptance rate is the cost of the smaller model,
/// and the question is whether the drop is worth 570 MB on every phone.
///
/// Off by default — it loads two models and runs inference, which takes
/// minutes. Run it deliberately:
///
///     VOXSCRIPTA_MODEL_COMPARISON=1 swift test --filter PolishModelComparison
@Suite("Polish model comparison", .serialized)
struct PolishModelComparison {

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["VOXSCRIPTA_MODEL_COMPARISON"] != nil
    }

    private static var modelsDirectory: URL {
        URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "build/models")
    }

    /// Disfluent speech of the kind CLEAN leaves behind for POLISH.
    ///
    /// Written rather than generated: these have to be sentences a polish
    /// model can plausibly improve, or both models score the same and the
    /// measurement says nothing. Filler words, false starts, repetition,
    /// run-ons and comma splices — what people actually say.
    private static let sentences: [String] = [
        "So the thing is, we need to, we need to ship this by Friday.",
        "I think that, um, the main issue is that the tests are slow.",
        "And then he said, he said that it wasn't going to work anyway.",
        "We tried it twice and both times it, it failed on the same step.",
        "The problem with that approach is it doesn't scale, it just doesn't.",
        "Basically what happened was the server went down and nobody noticed.",
        "I mean, you could do it that way, but it would be really slow.",
        "There's a lot of, there's a lot of moving parts in this system.",
        "We should probably, like, test it on a real device before we ship.",
        "The thing that worries me is we haven't run it on Linux at all.",
        "He mentioned it in the meeting but I don't think anyone wrote it down.",
        "It works on my machine, which is not the same as it working.",
        "We can either fix it now or we can fix it later, but later costs more.",
        "The migration took four hours and most of that was waiting for indexes.",
        "I'd rather ship something small that works than something big that doesn't.",
        "Nobody has actually looked at the logs since the deploy on Tuesday.",
        "If we do it that way then we have to maintain two versions forever.",
        "The customer said it was urgent but they say that about everything.",
        "We measured it and it turns out the bottleneck wasn't where we thought.",
        "It's not that it's hard, it's that it's tedious and nobody wants to.",
    ]

    private func transcript() -> Transcript {
        var start = MediaTime.zero
        let segments = Self.sentences.map { text -> TranscriptSegment in
            let end = start + .seconds(4)
            defer { start = end }
            return TranscriptSegment(originalStart: start, originalEnd: end, text: text)
        }
        return Transcript(variant: .clean, segments: segments,
                          provenance: Provenance(generatedAt: Date(), appVersion: "comparison"))
    }

    private struct Score {
        let model: String
        let megabytes: Int
        let accepted: Int
        let afterRetry: Int
        let keptClean: Int
        let failed: Int
        let seconds: Double
        /// Revisions that actually differ from the sentence they replaced.
        let changed: Int
        /// Mean absolute change in length, as a crude edit magnitude.
        let meanDelta: Double
        let examples: [(original: String, revised: String)]

        var total: Int { accepted + afterRetry + keptClean + failed }
        var acceptedRate: Double { Double(accepted + afterRetry) / Double(total) * 100 }
        /// The number that matters next to acceptance: a model that changes
        /// nothing is accepted every time and has improved nothing.
        var changedRate: Double { Double(changed) / Double(total) * 100 }
    }

    private func score(_ fileName: String) async throws -> Score {
        let url = Self.modelsDirectory.appending(path: fileName)
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "missing \(fileName) — see Tools/fetch-polish-model.sh")
        let bytes = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        let host = LlamaModelHost(modelURL: url)
        try await host.load()
        defer { Task { await host.unload() } }

        let began = Date()
        let result = try await PolishProcessor().process(clean: transcript(), host: host)
        let elapsed = Date().timeIntervalSince(began)

        let pairs = result.sentences.map { (original: $0.original, revised: $0.revised) }
        let differing = pairs.filter { $0.original != $0.revised }
        let delta = pairs.isEmpty ? 0 : pairs
            .map { abs(Double($0.revised.count - $0.original.count)) }
            .reduce(0, +) / Double(pairs.count)

        return Score(
            model: fileName,
            megabytes: bytes / 1_000_000,
            accepted: result.count(.accepted),
            afterRetry: result.count(.acceptedAfterRetry),
            keptClean: result.count(.fellBackToClean),
            failed: result.count(.modelFailed),
            seconds: elapsed,
            changed: differing.count,
            meanDelta: delta,
            examples: Array(differing.prefix(3)))
    }

    @Test("1.5B against 0.5B, on the same sentences",
          .enabled(if: PolishModelComparison.enabled))
    func compare() async throws {
        let big = try await score("polish.gguf")
        let small = try await score("polish-0.5b.gguf")

        for s in [big, small] {
            print(String(
                format: "%-20s %5d MB  %5.1f%% accepted  %5.1f%% actually changed  mean Δ %4.1f chars  %6.1fs",
                (s.model as NSString).utf8String!, s.megabytes,
                s.acceptedRate, s.changedRate, s.meanDelta, s.seconds))
        }
        print("")
        for s in [big, small] {
            print("── \(s.model)")
            for e in s.examples {
                print("   was: \(e.original)")
                print("   now: \(e.revised)")
            }
        }
        let saved = big.megabytes - small.megabytes
        print(String(format: "\nsmaller saves %d MB · acceptance %+.1f pts · edits made %+.1f pts",
                     saved, small.acceptedRate - big.acceptedRate,
                     small.changedRate - big.changedRate))

        // No pass/fail threshold. The decision — whether the drop is worth
        // 570 MB on every phone — is the user's, and inventing a bar here
        // would be dressing a judgement up as a test.
        #expect(big.total == small.total, "both models must see the same sentences")
    }
}
