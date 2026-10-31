import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// The llama.cpp polish backend, checked the way the MLX one is.
///
/// POLISH is the only stage that can change what a sentence means, so a new
/// backend is not proven by producing text. It is proven by producing text the
/// existing gauntlet accepts, and by being refused when it should be — which
/// is what the Spanish rejection corpus already measures for the other
/// backend.
///
/// Skipped without a model. It is a gigabyte and is fetched by
/// `Tools/fetch-polish-model.sh`, so these must not fail on a machine that has
/// not fetched it.
@Suite("Llama polish backend")
struct LlamaHostTests {

    private var modelIsAvailable: Bool {
        FileManager.default.fileExists(atPath: LlamaModelHost.defaultModelURL().path)
    }

    private func withHost<T>(_ body: (LlamaModelHost) async throws -> T) async throws -> T {
        let host = LlamaModelHost()
        try await host.load()
        do {
            let result = try await body(host)
            await host.unload()
            return result
        } catch {
            await host.unload()
            throw error
        }
    }

    // MARK: - Without a model

    @Test("It declares itself as the portable backend at temperature zero")
    func configuration() {
        let host = LlamaModelHost(modelURL: URL(filePath: "/tmp/x.gguf"))
        #expect(host.configuration.backend == .llama)
        #expect(host.configuration.temperature == 0)
        #expect(host.configuration.modelIdentifier == "x.gguf")
    }

    @Test("A missing model is a missing asset, not a crash")
    func missingModel() async {
        let host = LlamaModelHost(modelURL: URL(filePath: "/nonexistent/polish.gguf"))
        await #expect(throws: VoxScriptaError.self) { try await host.load() }
        #expect(await host.isReady() == false)
    }

    @Test("Both local backends share one prompt and one cleaner")
    func sharedPrompting() {
        // The guard against the two backends drifting. If this stops holding,
        // a transcript reads differently on a phone than on a PC for no reason
        // anyone chose.
        let prompt = LocalPrompting.prompt(
            for: "no aprobamos el presupuesto",
            context: PolishContext(preceding: [], following: []),
            language: .spanish)
        #expect(prompt.contains("español"))
        #expect(!prompt.lowercased().contains("rewrite this one sentence"))
        #expect(LocalPrompting.clean("\"Hello.\"", fallingBackTo: "x") == "Hello.")
    }

    // MARK: - With a model

    @Test("It returns exactly one rewrite per sentence")
    func cardinality() async throws {
        try #require(modelIsAvailable, "no model — run Tools/fetch-polish-model.sh")
        let sentences = ["we sold five hundred units in the third quarter",
                         "david met with sarah chen on tuesday",
                         "we did not approve the revised budget"]
        let revised = try await withHost { host in
            try await host.rewrite(
                sentences: sentences,
                context: PolishContext(preceding: [], following: []),
                instructions: PolishPrompt.instructions(for: .english),
                language: .english)
        }
        // Cardinality is true by construction here — one call per sentence —
        // rather than enforced by a schema. This is the test that says so.
        #expect(revised.count == sentences.count)
        for text in revised { #expect(!text.isEmpty) }
        for (original, text) in zip(sentences, revised) {
            print("  - \(original)\n  + \(text)")
        }
    }

    @Test("What it produces survives the gauntlet")
    func outputPassesValidation() async throws {
        try #require(modelIsAvailable, "no model — run Tools/fetch-polish-model.sh")
        let sentences = ["we sold five hundred units in the third quarter",
                         "we did not approve the revised budget",
                         "david met with sarah chen on tuesday"]
        let revised = try await withHost { host in
            try await host.rewrite(
                sentences: sentences,
                context: PolishContext(preceding: [], following: []),
                instructions: PolishPrompt.instructions(for: .english),
                language: .english)
        }
        let report = try ValidationGauntlet().validate(
            original: sentences, revised: revised, language: .english)
        print("LLAMA validation: passed=\(report.passed) failures=\(report.failureReasons)")
        // The point of a polish backend is output the gauntlet accepts. A
        // backend whose every rewrite is rejected is not a backend, it is an
        // expensive way to keep the clean transcript.
        #expect(report.passed, "the gauntlet rejected it: \(report.failureReasons)")
    }

    @Test("Spanish stays Spanish")
    func spanishIsNotTranslated() async throws {
        try #require(modelIsAvailable, "no model — run Tools/fetch-polish-model.sh")
        // The failure this project has already had once: English scaffolding
        // around Spanish content makes the model answer in English, and a
        // translated sentence fails every check there is.
        let sentences = ["no aprobamos el presupuesto el lunes"]
        let revised = try await withHost { host in
            try await host.rewrite(
                sentences: sentences,
                context: PolishContext(preceding: [], following: []),
                instructions: PolishPrompt.instructions(for: .spanish),
                language: .spanish)
        }
        let text = try #require(revised.first)
        print("LLAMA es: \(text)")
        let detected = LanguageDetection.dominantLanguage(of: text, minimumWords: 3)
        #expect(detected?.code != "en", "it answered in English: \(text)")
        // And the negation must still be there, which is the check the Spanish
        // corpus exists to protect.
        #expect(text.lowercased().contains("no "), "the negation was dropped: \(text)")
    }

    @Test("The same sentence twice gives the same answer")
    func deterministic() async throws {
        try #require(modelIsAvailable, "no model — run Tools/fetch-polish-model.sh")
        // Greedy decoding, so this is not a tendency, it is a guarantee — and
        // the provenance written into every polished transcript depends on it.
        let sentence = ["the committee has not scheduled a follow up"]
        let runs = try await withHost { host -> [String] in
            var out: [String] = []
            for _ in 0..<2 {
                out += try await host.rewrite(
                    sentences: sentence,
                    context: PolishContext(preceding: [], following: []),
                    instructions: PolishPrompt.instructions(for: .english),
                    language: .english)
            }
            return out
        }
        #expect(runs[0] == runs[1], "two runs differed:\n  \(runs[0])\n  \(runs[1])")
    }
}
