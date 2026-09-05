import Foundation
import VoxVerbaCore
import VoxVerbaLanguage

/// A scriptable stand-in for the on-device model.
///
/// The polish processor's own logic — windowing, retry, fallback, provenance —
/// deserves precise tests, and none of it should depend on what a language model
/// happens to say today. This host returns exactly what a test tells it to.
public actor MockLanguageModelHost: LanguageModelHosting {
    public enum Behaviour: Sendable {
        /// Return the input unchanged.
        case echo
        /// Apply a transformation to each sentence.
        case transform(@Sendable (String) -> String)
        /// Fail the first attempt, then behave well. Exercises the retry path.
        case failFirstThenEcho
        /// Return output that will not validate, always.
        case alwaysCorrupt(@Sendable (String) -> String)
        /// Throw, as an unavailable model would.
        case unavailable
    }

    public nonisolated let configuration: LanguageModelConfiguration
    private var behaviour: Behaviour
    private var loaded = false

    public private(set) var callCount = 0
    /// Instructions received on each call, so a test can assert the retry
    /// prompt actually names the violations.
    public private(set) var instructionsSeen: [String] = []
    public private(set) var contextsSeen: [PolishContext] = []

    public init(behaviour: Behaviour = .echo,
                configuration: LanguageModelConfiguration = .default) {
        self.behaviour = behaviour
        self.configuration = configuration
    }

    public func setBehaviour(_ behaviour: Behaviour) { self.behaviour = behaviour }

    public func isReady() async -> Bool { loaded }
    public func load() async throws { loaded = true }
    public func unload() async { loaded = false }

    public func rewrite(
        sentences: [String],
        context: PolishContext,
        instructions: String
    ) async throws -> [String] {
        callCount += 1
        instructionsSeen.append(instructions)
        contextsSeen.append(context)

        switch behaviour {
        case .echo:
            return sentences
        case .transform(let f):
            return sentences.map(f)
        case .failFirstThenEcho:
            // The processor retries with stricter instructions; the second call
            // returns something acceptable.
            return callCount == 1 ? sentences.map { $0 + " We also shipped 900 extra units." }
                                  : sentences
        case .alwaysCorrupt(let f):
            return sentences.map(f)
        case .unavailable:
            throw VoxVerbaError.modelUnavailable(.systemDefault, reason: "mock model is unavailable")
        }
    }
}
