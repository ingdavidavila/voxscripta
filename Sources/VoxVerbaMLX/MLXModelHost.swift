import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
@preconcurrency import Tokenizers
import VoxVerbaCore
import VoxVerbaLanguage

/// Loads model weights from a directory that is already on disk.
///
/// The app ships without a network entitlement, so nothing here may fetch: the
/// `Downloader` protocol exists for the Hugging Face path and is satisfied by
/// simply returning the local directory it was given.
struct LocalDirectoryDownloader: Downloader {
    let directory: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        directory
    }
}

/// Builds a tokenizer from files already in the model directory.
///
/// `mlx-swift-lm` defines the `Tokenizer` protocol but leaves the implementation
/// to the consumer; `#adaptHuggingFaceTokenizer` bridges the swift-transformers
/// type across. Reading a local folder, so still no network.
struct LocalTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return #adaptHuggingFaceTokenizer(upstream)
    }
}

/// A language model backend that runs entirely from bundled weights.
///
/// This is what makes VoxVerba independent of Apple Intelligence. The system
/// model is excellent and costs nothing to ship, but it is unavailable on an
/// ineligible Mac or one with the feature switched off, and there POLISHED
/// simply would not run. A bundled model removes that dependency.
///
/// - Note: The `MLXLanguageModel` bridge that plugs MLX into `LanguageModelSession`
///   — and with it `@Generable` guided generation — requires **macOS 27**; the
///   package gates it behind `canImport(FoundationModels, _version: 2)`. On
///   macOS 26 this drives `MLXLLM` directly instead. The practical cost is small,
///   because polish already runs one sentence per call: with a single sentence in
///   and a single sentence expected out, there is no cardinality for a schema to
///   enforce, and the seven validator checks are unchanged.
public actor MLXModelHost: LanguageModelHosting {
    public nonisolated let configuration: LanguageModelConfiguration
    public nonisolated let modelDirectory: URL

    private var container: ModelContainer?

    public init(modelDirectory: URL,
                configuration: LanguageModelConfiguration = .init(backend: .mlx)) {
        self.modelDirectory = modelDirectory
        self.configuration = configuration
    }

    /// A host backed by the model inside the app bundle, if one shipped.
    public static func bundled() -> MLXModelHost? {
        ModelLocator.bundledDirectory.map { MLXModelHost(modelDirectory: $0) }
    }

    public func isReady() async -> Bool { container != nil }

    public func load() async throws {
        guard container == nil else { return }
        guard ModelLocator.isUsable(modelDirectory) else {
            throw VoxVerbaError.modelUnavailable(
                ModelID(backend: "mlx", identifier: modelDirectory.lastPathComponent),
                reason: "no usable model at \(modelDirectory.path) — a config.json, "
                    + "tokenizer.json and weights are required")
        }
        do {
            container = try await loadModelContainer(
                from: LocalDirectoryDownloader(directory: modelDirectory),
                using: LocalTokenizerLoader(),
                configuration: ModelConfiguration(directory: modelDirectory))
        } catch {
            throw VoxVerbaError.modelUnavailable(
                ModelID(backend: "mlx", identifier: modelDirectory.lastPathComponent),
                reason: error.localizedDescription)
        }
    }

    public func unload() async {
        // Dropping the container releases the weights. Polish is a phase, so the
        // memory is genuinely reclaimed rather than held for a job that has
        // already finished.
        container = nil
    }

    public func rewrite(
        sentences: [String],
        context: PolishContext,
        instructions: String
    ) async throws -> [String] {
        guard !sentences.isEmpty else { return [] }
        if container == nil { try await load() }
        guard let container else {
            throw VoxVerbaError.modelUnavailable(.systemDefault, reason: "the model is not loaded")
        }

        var revised: [String] = []
        revised.reserveCapacity(sentences.count)

        // One sentence per call, matching the Apple backend. A fresh session each
        // time, so nothing accumulates across sentences and every call sees the
        // same context — which is what keeps output reproducible.
        for sentence in sentences {
            let session = ChatSession(
                container,
                instructions: instructions,
                generateParameters: GenerateParameters(
                    maxTokens: Self.tokenBudget(for: sentence),
                    temperature: 0))

            let raw: String
            do {
                raw = try await session.respond(to: Self.prompt(for: sentence, context: context))
            } catch {
                throw VoxVerbaError.modelUnavailable(
                    ModelID(backend: "mlx", identifier: modelDirectory.lastPathComponent),
                    reason: error.localizedDescription)
            }
            revised.append(Self.clean(raw, fallingBackTo: sentence))
        }
        return revised
    }

    // MARK: - Prompting

    static func prompt(for sentence: String, context: PolishContext) -> String {
        var parts: [String] = []
        if !context.preceding.isEmpty {
            parts.append("Earlier context (do not rewrite, do not repeat):\n"
                         + context.preceding.joined(separator: " "))
        }
        if !context.following.isEmpty {
            parts.append("Later context (do not rewrite, do not repeat):\n"
                         + context.following.joined(separator: " "))
        }
        // The output contract is stated last, because a small model weights the
        // end of a prompt heavily.
        parts.append("""
            Rewrite this one sentence:
            \(sentence)

            Reply with the rewritten sentence and nothing else. No preamble, no \
            quotation marks, no explanation.
            """)
        return parts.joined(separator: "\n\n")
    }

    static func tokenBudget(for sentence: String) -> Int {
        let words = sentence.split(separator: " ").count
        return Swift.max(64, Swift.min(512, words * 4))
    }

    /// Strips the scaffolding a small instruct model tends to add.
    ///
    /// Larger models follow "reply with the sentence and nothing else"; smaller
    /// ones often wrap the answer in quotes or a preamble. Rather than let the
    /// validator reject those as content changes, the obvious wrappers are removed
    /// here. Anything still unrecognizable falls back to the original sentence,
    /// which the validator then passes trivially.
    static func clean(_ raw: String, fallingBackTo original: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Some models emit a reasoning block; keep only what follows it.
        if let range = text.range(of: "</think>") {
            text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A leading "Sure, here is the rewritten sentence:" and similar.
        if let colon = text.firstIndex(of: ":"),
           text.distance(from: text.startIndex, to: colon) < 60,
           text[text.startIndex..<colon].lowercased().contains("sentence") {
            text = String(text[text.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Surrounding quotation marks.
        for quote in ["\"", "'", "“", "”"] where text.hasPrefix(quote) && text.hasSuffix(quote) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        // Only the first line: a model that explains itself does so afterwards.
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
        }

        return text.isEmpty ? original : text
    }
}
