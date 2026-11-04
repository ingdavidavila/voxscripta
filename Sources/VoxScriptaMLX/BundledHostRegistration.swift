// MLX is Apple-only.
//
// `Package.swift` gates the mlx-swift-lm dependency to macOS and iOS, because
// on Linux mlx-swift reaches for its CUDA backend and fails on a missing
// cuda.h — which takes the whole package down rather than just this target.
// Gating the dependency alone is not enough: without this guard the same
// build then fails on a missing module instead. With it, VoxScriptaMLX
// compiles to an empty module off Apple, which is correct — nothing
// cross-platform depends on it, and polish off Apple runs through llama.cpp.
#if canImport(MLXLLM)
import Foundation
import VoxScriptaLanguage

extension MLXModelHost {

    /// Makes MLX the bundled backend for this process.
    ///
    /// ``PolishBackendResolver`` cannot name this host: it lives in
    /// ``VoxScriptaLanguage``, which everything including the pipeline depends
    /// on, and MLX pulls in a HuggingFace package that does not build for musl.
    /// So the dependency runs the other way — this module, which only the Apple
    /// apps link, hands the resolver a closure.
    ///
    /// Call it once at launch, before the first job. Until it is called,
    /// `.bundled` resolves to llama.cpp, which is correct for the command line
    /// and wrong for the apps, which ship safetensors and no GGUF.
    public static func registerAsBundledBackend() {
        PolishBackendResolver.registerBundledHost { directory in
            let host = directory.map { MLXModelHost(modelDirectory: $0) } ?? Self.bundled()
            guard let host, ModelLocator.isUsable(host.modelDirectory) else { return nil }
            return PolishBackendResolver.BundledHost(
                host: host,
                describedAs: ModelLocator.displayName(for: host.modelDirectory))
        }
    }
}

#endif
