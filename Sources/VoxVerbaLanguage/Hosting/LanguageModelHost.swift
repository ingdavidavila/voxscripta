import Foundation
import VoxVerbaCore

/// Which local backend serves the polish pass.
///
/// Both reach the model through the Foundation Models framework, so guided
/// generation, streaming and structured output work identically across them.
public enum LanguageBackend: String, Sendable, Codable, CaseIterable {
    /// Apple's on-device system model. No download, no bundle weight, ~4096-token
    /// context — which is not a constraint here, because the anti-hallucination
    /// design independently forces windows of a few hundred tokens.
    case system
    /// Any mlx-community model loaded through `MLXLanguageModel`. Roughly 5 GB for
    /// an 8B at 4-bit, comfortable on 24 GB.
    case mlx
}

public struct LanguageModelConfiguration: Hashable, Sendable, Codable {
    public var backend: LanguageBackend
    /// Model identifier. Ignored for `.system`.
    public var modelIdentifier: String?
    /// Zero, always, for the polish pass. Exposed because §29 asks for it.
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

/// Owns the loaded language model.
///
/// - Important: This protocol is where the XPC boundary goes. V1 runs the model
///   in-process for simplicity; moving the MLX backend into an XPC service in
///   V1.5 requires no change above this line. Drawing the seam now is what makes
///   that move cheap later — a 5 GB model in-process is both a crash risk and a
///   memory-reclamation problem.
public protocol LanguageModelHosting: Sendable {
    var configuration: LanguageModelConfiguration { get }
    var isLoaded: Bool { get async }

    func load() async throws
    /// Generates a response. Deterministic at temperature zero.
    func generate(prompt: String, systemInstructions: String) async throws -> String
    /// Unloads model weights. Called on leaving the polish phase so the memory
    /// is actually reclaimed rather than merely unreferenced.
    func unload() async
}

/// Phase 6 implementation site.
public actor LanguageModelHost: LanguageModelHosting {
    public nonisolated let configuration: LanguageModelConfiguration
    private var loaded = false

    public var isLoaded: Bool { loaded }

    public init(configuration: LanguageModelConfiguration = .default) {
        self.configuration = configuration
    }

    public func load() async throws {
        throw VoxVerbaError.notImplemented("LanguageModelHost.load — Phase 6")
    }

    public func generate(prompt: String, systemInstructions: String) async throws -> String {
        throw VoxVerbaError.notImplemented("LanguageModelHost.generate — Phase 6")
    }

    public func unload() async { loaded = false }
}
