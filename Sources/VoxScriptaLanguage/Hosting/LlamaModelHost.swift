import Foundation
import CLlama
import VoxScriptaCore

/// POLISH on the platforms Apple's model does not reach.
///
/// llama.cpp, linked as a static library, running a GGUF model from disk. It
/// is the counterpart to ``MLXModelHost``: same prompt, same cleaning, same
/// one-sentence-per-call contract, so the only thing that differs between a
/// Mac and a PC is which library does the arithmetic.
///
/// Sharing matters more here than anywhere else in the port. POLISH is the one
/// stage that can change what a sentence means, which is why it sits behind an
/// eight-check gauntlet. Two backends with two prompts would be two behaviours
/// to validate; both call ``LocalPrompting`` instead.
///
/// An actor because a `llama_context` is a C pointer that must not be decoded
/// from two tasks at once.
public actor LlamaModelHost: LanguageModelHosting {

    public nonisolated let configuration: LanguageModelConfiguration

    private let modelURL: URL
    private let threads: Int32
    private var model: OpaquePointer?

    /// - Parameters:
    ///   - modelURL: A GGUF file. Resolved by ``defaultModelURL()`` otherwise.
    ///   - threads: Decoding threads; half the cores by default, which is what
    ///     llama.cpp's own tools settle on for a machine doing anything else.
    public init(modelURL: URL? = nil, threads: Int? = nil) {
        self.modelURL = modelURL ?? Self.defaultModelURL()
        let cores = ProcessInfo.processInfo.activeProcessorCount
        self.threads = Int32(max(1, threads ?? max(1, cores / 2)))
        self.configuration = LanguageModelConfiguration(
            backend: .llama,
            modelIdentifier: (modelURL ?? Self.defaultModelURL()).lastPathComponent,
            temperature: 0,
            maximumContextTokens: Self.contextTokens)
    }

    /// Context window given to the model.
    ///
    /// One sentence plus its surrounding context, not a transcript, so this is
    /// sized for a window rather than a document. It matches what the polish
    /// stage already promises about window size.
    static let contextTokens = 4096

    public static func defaultModelURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VOXSCRIPTA_LLAMA_MODEL"] {
            return URL(filePath: override)
        }
        return URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "build/models/polish.gguf")
    }

    public func isReady() async -> Bool { model != nil }

    // MARK: - Loading

    public func load() async throws {
        if model != nil { return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw VoxScriptaError.modelAssetMissing(
                description: "no GGUF model at \(modelURL.path) — "
                    + "run Tools/fetch-polish-model.sh")
        }
        // llama.cpp logs the whole load at info level. The pipeline reports its
        // own progress, and a wall of backend chatter in the middle of it is
        // noise, so the library is quietened before anything is opened.
        llama_log_set({ level, _, _ in _ = level }, nil)
        ggml_backend_load_all()

        var params = llama_model_default_params()
        params.n_gpu_layers = 99
        guard let opened = llama_model_load_from_file(modelURL.path, params) else {
            throw VoxScriptaError.modelUnavailable(
                ModelID(backend: "llama.cpp", identifier: modelURL.lastPathComponent),
                reason: "the model would not load")
        }
        model = opened
    }

    public func unload() async {
        if let model { llama_model_free(model) }
        model = nil
    }

    // MARK: - Rewriting

    public func rewrite(
        sentences: [String],
        context: PolishContext,
        instructions: String,
        language: TranscriptLanguage
    ) async throws -> [String] {
        guard !sentences.isEmpty else { return [] }
        if model == nil { try await load() }
        guard let model else {
            throw VoxScriptaError.modelUnavailable(
                ModelID(backend: "llama.cpp", identifier: modelURL.lastPathComponent),
                reason: "the model is not loaded")
        }

        var revised: [String] = []
        revised.reserveCapacity(sentences.count)
        // One sentence per call with a fresh context, exactly as the MLX
        // backend does it. Cardinality is then true by construction rather
        // than enforced by a schema the backend has to support, and nothing
        // carries over from one sentence to the next, which is what keeps the
        // output reproducible.
        for sentence in sentences {
            let prompt = Self.chatPrompt(
                model: model,
                instructions: instructions,
                user: LocalPrompting.prompt(for: sentence, context: context, language: language))
            let raw = try generate(
                prompt: prompt, model: model,
                limit: LocalPrompting.tokenBudget(for: sentence))
            revised.append(LocalPrompting.clean(raw, fallingBackTo: sentence))
        }
        return revised
    }

    // MARK: - The model

    /// Applies the model's own chat template.
    ///
    /// Taken from the GGUF rather than written here: an instruct model that is
    /// prompted in the wrong format answers noticeably worse, and every family
    /// marks turns differently. Falls back to the plain text when a model
    /// carries no template, which is right for a base model.
    static func chatPrompt(model: OpaquePointer, instructions: String, user: String) -> String {
        let template = llama_model_chat_template(model, nil)
        guard let template else { return instructions + "\n\n" + user }

        return instructions.withCString { systemText in
            user.withCString { userText in
                var messages = [
                    llama_chat_message(role: strdup("system"), content: strdup(systemText)),
                    llama_chat_message(role: strdup("user"), content: strdup(userText)),
                ]
                defer {
                    for message in messages {
                        free(UnsafeMutableRawPointer(mutating: message.role))
                        free(UnsafeMutableRawPointer(mutating: message.content))
                    }
                }
                var buffer = [CChar](repeating: 0, count: (instructions.utf8.count
                                                           + user.utf8.count) * 2 + 1024)
                let written = llama_chat_apply_template(
                    template, &messages, messages.count, true, &buffer, Int32(buffer.count))
                guard written > 0 else { return instructions + "\n\n" + user }
                return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) },
                              as: UTF8.self)
            }
        }
    }

    /// Greedy decoding until the model stops or the budget runs out.
    ///
    /// Greedy rather than temperature zero: no sampling happens at all, so two
    /// runs of the same window return the same text. The polish stage's whole
    /// provenance story depends on that being true.
    private func generate(prompt: String, model: OpaquePointer, limit: Int) throws -> String {
        let vocabulary = llama_model_get_vocab(model)

        var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 64)
        let count = llama_tokenize(vocabulary, prompt, Int32(prompt.utf8.count),
                                   &tokens, Int32(tokens.count), true, true)
        guard count > 0 else {
            throw VoxScriptaError.modelUnavailable(
                ModelID(backend: "llama.cpp", identifier: modelURL.lastPathComponent),
                reason: "the prompt could not be tokenized")
        }
        tokens = Array(tokens.prefix(Int(count)))

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(Self.contextTokens)
        contextParams.n_batch = UInt32(max(Int(count), 512))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParams) else {
            throw VoxScriptaError.modelUnavailable(
                ModelID(backend: "llama.cpp", identifier: modelURL.lastPathComponent),
                reason: "a context could not be created")
        }
        defer { llama_free(context) }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var batch = tokens.withUnsafeMutableBufferPointer {
            llama_batch_get_one($0.baseAddress, Int32($0.count))
        }
        var output = ""
        var produced = 0

        while produced < limit {
            guard llama_decode(context, batch) == 0 else {
                throw VoxScriptaError.modelUnavailable(
                    ModelID(backend: "llama.cpp", identifier: modelURL.lastPathComponent),
                    reason: "decoding failed")
            }
            var next = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, next) { break }

            var piece = [CChar](repeating: 0, count: 256)
            let length = llama_token_to_piece(vocabulary, next, &piece,
                                              Int32(piece.count), 0, true)
            if length > 0 {
                output += String(decoding: piece.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                                 as: UTF8.self)
            }
            produced += 1
            batch = llama_batch_get_one(&next, 1)
        }
        return output
    }
}
