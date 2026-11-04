import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// Which model actually runs.
///
/// Worth its own suite because the answer moved. `PolishBackendResolver` used
/// to live in the pipeline and name ``MLXModelHost`` outright; it now takes a
/// registration from whichever layer ships a model, so that the pipeline can
/// cross-compile. That is exactly the sort of indirection that can change a
/// user's polish backend without anyone noticing, so the slot is pinned here:
/// a registered host wins, an absent one does not silently become something
/// else, and `.system` is still refused by name rather than substituted.
///
/// The registration is process-global, so every test restores it. They are
/// marked `.serialized` for the same reason.
@Suite("Polish backend resolution", .serialized)
struct PolishBackendResolverTests {

    /// A host that cannot do anything. These tests ask which backend was
    /// chosen, never what it produces, so there is nothing to load.
    private actor StubHost: LanguageModelHosting {
        nonisolated let configuration = LanguageModelConfiguration(backend: .mlx)
        func isReady() async -> Bool { true }
        func load() async throws {}
        func unload() async {}
        func rewrite(sentences: [String], context: PolishContext,
                     instructions: String, language: TranscriptLanguage) async throws -> [String] {
            sentences
        }
    }

    /// Runs `body` with `provider` registered, then puts the process back.
    private func withRegistration<T>(
        _ provider: PolishBackendResolver.BundledHostProvider?,
        _ body: () throws -> T
    ) rethrows -> T {
        PolishBackendResolver.registerBundledHost(provider)
        defer { PolishBackendResolver.registerBundledHost(nil) }
        return try body()
    }

    @Test("A registered host is what .bundled resolves to")
    func registeredHostWins() throws {
        let resolved = try withRegistration({ _ in
            PolishBackendResolver.BundledHost(host: StubHost(), describedAs: "stub-model")
        }) {
            try PolishBackendResolver.resolve(.bundled)
        }
        #expect(resolved.kind == .bundled)
        #expect(resolved.describedAs == "stub-model")
    }

    @Test("The model directory reaches the provider unchanged")
    func directoryIsForwarded() throws {
        let asked = URL(filePath: "/models/something-larger")
        let resolved = try withRegistration({ directory in
            PolishBackendResolver.BundledHost(
                host: StubHost(), describedAs: directory?.lastPathComponent ?? "<none>")
        }) {
            try PolishBackendResolver.resolve(.bundled, modelDirectory: asked)
        }
        #expect(resolved.describedAs == "something-larger")
    }

    @Test("A provider that declines does not become some other model")
    func decliningProviderThrows() throws {
        // The provider returning nil means "this build ships nothing usable".
        // The fallback below it is llama.cpp, which is only offered when its
        // GGUF is on disk — so point the search somewhere it certainly is not,
        // and the resolver must decline rather than hand back a host that
        // would fail at load() in the middle of a job.
        let missing = URL(filePath: "/nonexistent/polish.gguf")
        #expect(throws: VoxScriptaError.self) {
            try withRegistration({ _ in nil }) {
                try PolishBackendResolver.resolve(.bundled, modelDirectory: missing)
            }
        }
    }

    @Test("llama.cpp is the fallback when nothing registered and a GGUF exists")
    func llamaFallback() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "resolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Not a real model — nothing is loaded here. The resolver's contract is
        // that it checks for the file, and that is what is being checked.
        let gguf = directory.appending(path: "polish.gguf")
        try Data("not a model".utf8).write(to: gguf)

        let resolved = try PolishBackendResolver.resolve(.bundled, modelDirectory: gguf)
        #expect(resolved.kind == .bundled)
        #expect(resolved.describedAs == "llama.cpp, polish.gguf")
        #expect(resolved.host.configuration.backend == .llama)
    }

    @Test("A named .system is refused rather than substituted")
    func systemIsNeverSubstituted() throws {
        // A registered bundled host is available throughout, so if `.system`
        // ever fell back this would succeed with `.bundled`. On a Mac with
        // Apple Intelligence on it legitimately succeeds with `.system`; the
        // one outcome the test rejects is the substitution.
        let resolved = try? withRegistration({ _ in
            PolishBackendResolver.BundledHost(host: StubHost(), describedAs: "stub-model")
        }) {
            try PolishBackendResolver.resolve(.system)
        }
        if let resolved {
            #expect(resolved.kind == .system)
        }
    }
}
