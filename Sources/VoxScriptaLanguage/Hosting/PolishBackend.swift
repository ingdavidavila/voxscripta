import Foundation
import VoxScriptaCore

/// Which language model the polish pass should use.
public enum PolishBackendPreference: String, Sendable, Codable, CaseIterable {
    /// Prefer the system model, fall back to a local one.
    ///
    /// The default, and the reason POLISHED can be promised unconditionally. The
    /// system model is better — larger, tuned, and running in another process so
    /// its memory never lands in this app — but it is absent on an ineligible Mac
    /// or one with Apple Intelligence switched off, and does not exist at all on
    /// Android, Windows or Linux. A local model is the floor beneath it.
    case automatic
    /// Apple's on-device system model only.
    case system
    /// A model that ships with, or is pointed at by, this build only.
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

    public init(host: any LanguageModelHosting, kind: PolishBackendPreference,
                describedAs: String) {
        self.host = host
        self.kind = kind
        self.describedAs = describedAs
    }
}

/// Chooses a language model host.
///
/// This used to live in `VoxScriptaPipeline`, which meant the pipeline imported
/// ``VoxScriptaMLX`` to name one of the answers — and so pulled a HuggingFace
/// package that does not build for musl into every module above it. The
/// pipeline is the one part of this project that must run everywhere, so the
/// dependency is inverted here: this resolver names only the hosts
/// ``VoxScriptaLanguage`` itself owns, and a build that ships an MLX model
/// *registers* it from above through ``registerBundledHost(_:)``.
///
/// The consequence is worth stating plainly rather than hiding in the
/// indirection: `.bundled` resolves to whatever the process registered. The Mac
/// and iOS apps register MLX at launch, so they behave exactly as before. The
/// command line registers nothing — it has to cross-compile — so `.bundled`
/// there is llama.cpp reading a GGUF file. Same prompt, same cleaning, same
/// gauntlet; a different library doing the arithmetic, and `describedAs` says
/// which.
public enum PolishBackendResolver {

    /// A locally shipped model, as the layer that owns it describes it.
    public struct BundledHost: Sendable {
        public let host: any LanguageModelHosting
        public let describedAs: String

        public init(host: any LanguageModelHosting, describedAs: String) {
            self.host = host
            self.describedAs = describedAs
        }
    }

    /// Builds the bundled host, given an explicit model folder when one was
    /// asked for. Returns `nil` when this build ships no usable model.
    public typealias BundledHostProvider = @Sendable (URL?) -> BundledHost?

    /// Registers the bundled model host for this process.
    ///
    /// Called once, early, by whichever layer links a model runtime: the apps
    /// call it with MLX. Replacing a registration is allowed and the last one
    /// wins, so a test can install a stub without the resolver needing a
    /// test-only branch.
    public static func registerBundledHost(_ provider: BundledHostProvider?) {
        BundledRegistry.shared.set(provider)
    }

    /// Resolves a preference against what this machine and this build have.
    ///
    /// - Throws: When the requested backend is unavailable and no fallback is
    ///   permitted. Polish then declines with a stated reason rather than the job
    ///   failing.
    /// - Parameter modelDirectory: An explicit model folder or file, overriding
    ///   whatever the build ships. Lets someone run a larger model than the app
    ///   came with, and lets the command line point at a GGUF outside a bundle.
    public static func resolve(
        _ preference: PolishBackendPreference,
        modelDirectory: URL? = nil
    ) throws -> ResolvedBackend {

        let bundled = bundledHost(modelDirectory: modelDirectory)

        switch preference {
        case .system:
            // Named rather than inferred, so it is refused rather than quietly
            // substituted. Someone who asked for Apple Intelligence should be
            // told it is absent, not handed a different model under its name.
            guard systemAvailable else { throw systemUnavailable() }
            return ResolvedBackend(host: systemHost(), kind: .system,
                                   describedAs: "Apple on-device model")

        case .bundled:
            guard let bundled else { throw bundledMissing() }
            return ResolvedBackend(host: bundled.host, kind: .bundled,
                                   describedAs: bundled.describedAs)

        case .automatic:
            if systemAvailable {
                return ResolvedBackend(host: systemHost(), kind: .system,
                                       describedAs: "Apple on-device model")
            }
            if let bundled {
                return ResolvedBackend(host: bundled.host, kind: .bundled,
                                       describedAs: bundled.describedAs)
            }
            throw VoxScriptaError.modelUnavailable(
                .systemDefault,
                reason: String(
                    localized: "no local language model is available to polish with"))
        }
    }

    /// Whether polish can run at all on this machine.
    public static func isAnyBackendAvailable() -> Bool {
        (try? resolve(.automatic)) != nil
    }

    // MARK: - The bundled model

    /// The registered host, or llama.cpp when nothing registered one.
    ///
    /// The fallback is not a consolation prize: llama.cpp is the backend every
    /// non-Apple platform uses, and it is measured by the same gauntlet. It is
    /// offered only when the GGUF is actually on disk, because a host that
    /// failed at `load()` would turn a clean "polish declined, here is why" into
    /// a stage error halfway through a job.
    private static func bundledHost(modelDirectory: URL?) -> BundledHost? {
        if let provider = BundledRegistry.shared.current,
           let registered = provider(modelDirectory) {
            return registered
        }
        let host = modelDirectory.map { LlamaModelHost(modelURL: $0) } ?? LlamaModelHost()
        guard FileManager.default.fileExists(atPath: host.modelURL.path) else { return nil }
        return BundledHost(host: host,
                           describedAs: "llama.cpp, " + host.modelURL.lastPathComponent)
    }

    private static func bundledMissing() -> VoxScriptaError {
        let path = LlamaModelHost.defaultModelURL().path
        return .modelAssetMissing(
            description: String(
                localized: "no bundled model, and no GGUF at \(path) — run Tools/fetch-polish-model.sh"))
    }

    // MARK: - The system model

    #if canImport(FoundationModels)
    private static var systemAvailable: Bool {
        (try? LanguageModelHost.availability().get()) != nil
    }

    private static func systemHost() -> any LanguageModelHosting { LanguageModelHost() }

    private static func systemUnavailable() -> VoxScriptaError {
        if case .failure(let error) = LanguageModelHost.availability() { return error }
        return .modelUnavailable(
            .systemDefault, reason: String(localized: "the system model is unavailable"))
    }
    #else
    private static var systemAvailable: Bool { false }

    /// Unreachable: every caller checks ``systemAvailable`` first, which is a
    /// compile-time `false` here. It exists so the switch above stays one piece
    /// of code on all platforms rather than two that can drift apart.
    private static func systemHost() -> any LanguageModelHosting {
        preconditionFailure("no system model on this platform")
    }

    private static func systemUnavailable() -> VoxScriptaError {
        .modelUnavailable(
            .systemDefault,
            reason: String(
                localized: "Apple's on-device model does not exist on this platform"))
    }
    #endif
}

/// Holds the registration. A class with a lock rather than an actor, because
/// ``PolishBackendResolver/resolve(_:modelDirectory:)`` is synchronous and
/// called from inside stages that are already on their own executor.
private final class BundledRegistry: @unchecked Sendable {
    static let shared = BundledRegistry()

    private let lock = NSLock()
    private var provider: PolishBackendResolver.BundledHostProvider?

    var current: PolishBackendResolver.BundledHostProvider? {
        lock.withLock { provider }
    }

    func set(_ newValue: PolishBackendResolver.BundledHostProvider?) {
        lock.withLock { provider = newValue }
    }
}
