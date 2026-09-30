import Foundation
import VoxScriptaCore
import VoxScriptaLanguage
import VoxScriptaMLX

/// Which language model the polish pass should use.
public enum PolishBackendPreference: String, Sendable, Codable, CaseIterable {
    /// Prefer the system model, fall back to the bundled one.
    ///
    /// The default, and the reason POLISHED can be promised unconditionally. The
    /// system model is better — larger, tuned, and running in another process so
    /// its memory never lands in this app — but it is absent on an ineligible Mac
    /// or one with Apple Intelligence switched off. The bundled model is the
    /// floor beneath it.
    case automatic
    /// Apple's on-device system model only.
    case system
    /// The model shipped inside the app only.
    case bundled

    public var displayName: String {
        switch self {
        case .automatic: "Best available"
        case .system: "Apple Intelligence"
        case .bundled: "Bundled model"
        }
    }
}

/// What actually ran, so the UI and provenance can say.
public struct ResolvedBackend: Sendable {
    public let host: any LanguageModelHosting
    public let kind: PolishBackendPreference
    public let describedAs: String
}

/// Chooses a language model host.
public enum PolishBackendResolver {

    /// Resolves a preference against what this machine actually has.
    ///
    /// - Throws: When the requested backend is unavailable and no fallback is
    ///   permitted. Polish then declines with a stated reason rather than the job
    ///   failing.
    /// - Parameter modelDirectory: An explicit model folder, overriding the
    ///   bundled one. Lets someone run a larger model than the app ships with,
    ///   and lets the command line exercise the MLX path outside an app bundle.
    public static func resolve(
        _ preference: PolishBackendPreference,
        modelDirectory: URL? = nil
    ) throws -> ResolvedBackend {
        let systemAvailable = (try? LanguageModelHost.availability().get()) != nil
        let bundled = modelDirectory.map { MLXModelHost(modelDirectory: $0) }
            ?? MLXModelHost.bundled()

        switch preference {
        case .system:
            guard systemAvailable else {
                throw systemUnavailable()
            }
            return ResolvedBackend(host: LanguageModelHost(), kind: .system,
                                   describedAs: "Apple on-device model")

        case .bundled:
            guard let bundled else { throw bundledMissing() }
            return ResolvedBackend(
                host: bundled, kind: .bundled,
                describedAs: ModelLocator.displayName(for: bundled.modelDirectory))

        case .automatic:
            if systemAvailable {
                return ResolvedBackend(host: LanguageModelHost(), kind: .system,
                                       describedAs: "Apple on-device model")
            }
            if let bundled {
                return ResolvedBackend(
                    host: bundled, kind: .bundled,
                    describedAs: ModelLocator.displayName(for: bundled.modelDirectory))
            }
            throw VoxScriptaError.modelUnavailable(
                .systemDefault,
                reason: "Apple Intelligence is unavailable and this build ships no "
                    + "bundled model, so there is nothing to polish with")
        }
    }

    /// Whether polish can run at all on this machine.
    public static func isAnyBackendAvailable() -> Bool {
        (try? resolve(.automatic)) != nil
    }

    private static func systemUnavailable() -> VoxScriptaError {
        if case .failure(let error) = LanguageModelHost.availability() { return error }
        return .modelUnavailable(.systemDefault, reason: "the system model is unavailable")
    }

    private static func bundledMissing() -> VoxScriptaError {
        .modelUnavailable(
            ModelID(backend: "mlx", identifier: "bundled"),
            reason: "this build ships no bundled model; rebuild with Tools/fetch-model.sh")
    }
}
