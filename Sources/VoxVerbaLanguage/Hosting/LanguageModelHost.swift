import Foundation
import FoundationModels
import VoxVerbaCore

/// Which local backend serves the polish pass.
public enum LanguageBackend: String, Sendable, Codable, CaseIterable {
    /// Apple's on-device system model through the Foundation Models framework.
    /// No download, no bundle weight, and it runs in a system process.
    case system
    /// Any mlx-community model through `MLXLanguageModel`. Not built yet — see
    /// ``LanguageModelHost`` for why.
    case mlx
}

public struct LanguageModelConfiguration: Hashable, Sendable, Codable {
    public var backend: LanguageBackend
    /// Model identifier. Ignored for `.system`.
    public var modelIdentifier: String?
    /// Zero, always, for the polish pass.
    ///
    /// The backend additionally uses greedy sampling, which is a stronger
    /// guarantee than a zero temperature: no sampling happens at all, so two runs
    /// of the same window return the same text. Verified on this machine.
    public var temperature: Double
    public var maximumContextTokens: Int

    public init(
        backend: LanguageBackend = .system,
        modelIdentifier: String? = nil,
        temperature: Double = 0,
        maximumContextTokens: Int = 4096
    ) {
        self.backend = backend
        self.modelIdentifier = modelIdentifier
        self.temperature = temperature
        self.maximumContextTokens = maximumContextTokens
    }

    public static let `default` = LanguageModelConfiguration()
}

/// Sentences either side of a window, given to the model as read-only context.
public struct PolishContext: Sendable {
    public let preceding: [String]
    public let following: [String]

    public init(preceding: [String] = [], following: [String] = []) {
        self.preceding = preceding
        self.following = following
    }
}

/// Owns the loaded language model.
///
/// - Important: This protocol is where the XPC boundary goes. V1 runs the model
///   in-process; moving a large MLX model into an XPC service later requires no
///   change above this line.
public protocol LanguageModelHosting: Sendable {
    var configuration: LanguageModelConfiguration { get }
    func isReady() async -> Bool
    func load() async throws

    /// Rewrites each sentence, returning exactly as many as it was given.
    ///
    /// Cardinality is part of the contract rather than a downstream check,
    /// because a backend that can enforce it structurally should.
    func rewrite(
        sentences: [String],
        context: PolishContext,
        instructions: String
    ) async throws -> [String]

    func unload() async
}

/// Builds a schema that admits exactly `count` sentences.
///
/// The count is a runtime value, so the schema is built dynamically rather than
/// declared with `@Generable`. This matters more than it looks: a compile-time
/// schema constrains only the *shape*, and the model merged sentences freely
/// inside it — two thirds of windows were rejected for cardinality alone, and
/// each rejection cost every sentence in its window. With
/// `minimumElements == maximumElements` the framework will not let the model
/// return the wrong number at all, so the failure mode disappears rather than
/// being caught downstream.
func rewriteSchema(count: Int) throws -> GenerationSchema {
    let root = DynamicGenerationSchema(
        name: "RewrittenWindow",
        properties: [.init(
            name: "sentences",
            description: "Exactly \(count) rewritten sentences, one per input sentence, in the same order.",
            schema: DynamicGenerationSchema(
                arrayOf: DynamicGenerationSchema(type: String.self),
                minimumElements: count, maximumElements: count))])
    return try GenerationSchema(root: root, dependencies: [])
}

/// The Apple on-device backend.
///
/// The MLX backend named in the architecture is deliberately not built here. It
/// requires `mlx-swift-lm`, a large dependency fetched over the network at build
/// time, which would end this project's zero-dependency, offline-buildable
/// property. The system model is sufficient for the task as designed — windows of
/// three to eight sentences, a few hundred tokens — so MLX becomes a quality tier
/// for users who want a larger model, not a prerequisite. The protocol above is
/// the seam; adding it is one conforming type.
public actor LanguageModelHost: LanguageModelHosting {
    public nonisolated let configuration: LanguageModelConfiguration
    private var session: LanguageModelSession?

    public init(configuration: LanguageModelConfiguration = .default) {
        self.configuration = configuration
    }

    public func isReady() async -> Bool {
        session != nil && SystemLanguageModel.default.isAvailable
    }

    /// Whether the on-device model can run at all, and why not when it cannot.
    public static func availability() -> Result<Void, VoxVerbaError> {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .success(())
        case .unavailable(let reason):
            let explanation = switch reason {
            case .deviceNotEligible:
                "this Mac does not support on-device language models"
            case .appleIntelligenceNotEnabled:
                "Apple Intelligence is turned off in System Settings"
            case .modelNotReady:
                "the on-device model is still downloading or preparing"
            @unknown default:
                "the on-device model is unavailable"
            }
            return .failure(.modelUnavailable(.systemDefault, reason: explanation))
        }
    }

    public func load() async throws {
        guard configuration.backend == .system else {
            throw VoxVerbaError.modelUnavailable(
                ModelID(backend: configuration.backend.rawValue,
                        identifier: configuration.modelIdentifier ?? "unspecified"),
                reason: "the MLX backend is not built in this version; use the system model")
        }
        if case .failure(let error) = Self.availability() { throw error }
        // A session is created per window rather than reused, so context cannot
        // accumulate across windows and push against the 4096-token limit.
        session = LanguageModelSession(instructions: "")
    }

    public func unload() async { session = nil }

    public func rewrite(
        sentences: [String],
        context: PolishContext,
        instructions: String
    ) async throws -> [String] {
        guard !sentences.isEmpty else { return [] }
        if case .failure(let error) = Self.availability() { throw error }

        let session = LanguageModelSession(instructions: instructions)
        let options = GenerationOptions(
            // Greedy rather than a zero temperature: no sampling at all, so the
            // same window returns the same text on every run.
            sampling: .greedy,
            temperature: configuration.temperature,
            maximumResponseTokens: Self.responseBudget(for: sentences))

        do {
            let response = try await session.respond(
                to: Self.prompt(sentences: sentences, context: context),
                schema: try rewriteSchema(count: sentences.count),
                options: options)
            return try response.content.value([String].self, forProperty: "sentences")
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.translate(error)
        } catch {
            throw VoxVerbaError.modelUnavailable(.systemDefault, reason: error.localizedDescription)
        }
    }

    // MARK: - Prompting

    /// Builds the window prompt.
    ///
    /// Surrounding sentences are supplied so a pronoun or a clause reference can
    /// be resolved, and are labelled explicitly as not-to-be-rewritten. Without
    /// them the model tends to expand pronouns into names it has to guess at,
    /// which the entity check then rejects.
    static func prompt(sentences: [String], context: PolishContext) -> String {
        var parts: [String] = []
        if !context.preceding.isEmpty {
            parts.append("CONTEXT BEFORE (do not rewrite, do not return):\n"
                         + context.preceding.joined(separator: "\n"))
        }
        parts.append("REWRITE THESE \(sentences.count) SENTENCE(S), returning exactly \(sentences.count):\n"
                     + sentences.enumerated()
                        .map { "\($0.offset + 1). \($0.element)" }
                        .joined(separator: "\n"))
        if !context.following.isEmpty {
            parts.append("CONTEXT AFTER (do not rewrite, do not return):\n"
                         + context.following.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// Generous but bounded: polish should be about as long as its input.
    static func responseBudget(for sentences: [String]) -> Int {
        let words = sentences.reduce(0) { $0 + $1.split(separator: " ").count }
        return Swift.max(128, Swift.min(2048, words * 3))
    }

    private static func translate(_ error: LanguageModelSession.GenerationError) -> VoxVerbaError {
        switch error {
        case .exceededContextWindowSize:
            .contextWindowExceeded(tokens: 0, limit: 4096)
        case .guardrailViolation:
            .validationRejected(reasons: ["the model's safety guardrail refused this passage"])
        default:
            .modelUnavailable(.systemDefault, reason: String(describing: error))
        }
    }
}
