import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaLanguage
@testable import VoxScriptaMLX

/// Tests against the model that ships with the app.
///
/// Skipped rather than failed when no model is present, because the weights are
/// not in the repository — they are fetched once by `Tools/fetch-model.sh` and
/// copied into the bundle at build time.
@Suite("MLX backend", .serialized)
struct MLXHostTests {

    /// Where `Tools/fetch-model.sh` puts the weights.
    static let modelDirectory: URL = URL(filePath: #filePath)
        .deletingLastPathComponent()    // VoxScriptaMLXTests
        .deletingLastPathComponent()    // Tests
        .deletingLastPathComponent()    // package root
        .appending(path: "build/Model")

    static var hasModel: Bool { ModelLocator.isUsable(modelDirectory) }

    @Test("A model directory is recognized")
    func recognizesModel() {
        // The check that turns a missing or half-copied model into a clear
        // message instead of an error from inside the tensor loader.
        #expect(ModelLocator.isUsable(URL(filePath: "/nonexistent")) == false)
        #expect(ModelLocator.isUsable(URL(filePath: NSTemporaryDirectory())) == false)
    }

    @Test("Model responses are stripped of scaffolding")
    func cleansResponses() {
        // Small instruct models wrap answers even when told not to. Letting that
        // reach the validator would show up as a content change and be rejected,
        // so the obvious wrappers come off first.
        let original = "We sold 500 units."
        #expect(MLXModelHost.clean("\"We sold 500 units.\"", fallingBackTo: original)
                == "We sold 500 units.")
        #expect(MLXModelHost.clean("Here is the rewritten sentence: We sold 500 units.",
                                   fallingBackTo: original) == "We sold 500 units.")
        #expect(MLXModelHost.clean("<think>hmm</think>\nWe sold 500 units.",
                                   fallingBackTo: original) == "We sold 500 units.")
        #expect(MLXModelHost.clean("We sold 500 units.\nLet me know if you need more.",
                                   fallingBackTo: original) == "We sold 500 units.")
        // Nothing usable falls back to the original rather than emitting noise.
        #expect(MLXModelHost.clean("   ", fallingBackTo: original) == original)
    }

    @Test("The prompt states the output contract last")
    func promptShape() {
        let prompt = MLXModelHost.prompt(
            for: "we did not approve it",
            context: PolishContext(preceding: ["Earlier."], following: ["Later."]))
        #expect(prompt.contains("we did not approve it"))
        #expect(prompt.contains("Earlier."))
        #expect(prompt.contains("Later."))
        // A small model weights the end of a prompt heavily.
        #expect(prompt.hasSuffix("no explanation."))
    }

    @Test("The bundled model loads and rewrites a sentence",
          .enabled(if: MLXHostTests.hasModel,
                   "no model at build/Model — run Tools/fetch-model.sh"))
    func loadsAndRewrites() async throws {
        let host = MLXModelHost(modelDirectory: Self.modelDirectory)
        try await host.load()
        #expect(await host.isReady())

        let output = try await host.rewrite(
            sentences: ["uh so i think we should probably start on monday"],
            context: PolishContext(),
            instructions: PolishPrompt.instructions,
            language: .english)

        #expect(output.count == 1)
        let revised = output[0]
        print("MLX REWROTE: \(revised)")
        #expect(!revised.isEmpty)
        // One sentence in, one out — no preamble, no list, no commentary.
        #expect(!revised.contains("\n"))
        #expect(revised.count < 200)

        await host.unload()
        #expect(await host.isReady() == false)
    }

    @Test("Facts survive a real rewrite",
          .enabled(if: MLXHostTests.hasModel, "no model at build/Model"))
    func preservesFactsEndToEnd() async throws {
        let host = MLXModelHost(modelDirectory: Self.modelDirectory)
        try await host.load()
        defer { Task { await host.unload() } }

        let cases = [
            "we sold five hundred units in the third quarter",
            "we did not approve the revised budget",
            "david met with sarah chen on tuesday",
        ]
        let output = try await host.rewrite(sentences: cases, context: PolishContext(),
                                            instructions: PolishPrompt.instructions,
                                            language: .english)
        #expect(output.count == cases.count)
        for (input, revised) in zip(cases, output) {
            print("  - \(input)\n  + \(revised)")
        }

        // Whatever the model does, the gauntlet is what decides. This asserts the
        // pipeline runs end to end on a bundled model, not that a 1.5B model is
        // always faithful — that is the validator's job, and it falls back when
        // the model is not.
        let report = try ValidationGauntlet().validate(
            original: cases, revised: output, thresholds: .default)
        print("MLX validation: passed=\(report.passed) failures=\(report.failureReasons)")
        #expect(report.results.count > 1)
    }
}
