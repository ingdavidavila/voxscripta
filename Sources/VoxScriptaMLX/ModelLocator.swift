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
import VoxScriptaCore

/// Finds the language model weights on disk.
///
/// The app has no network entitlement and cannot fetch anything, so a model has
/// to already be present. Two places are searched, in order:
///
/// 1. **Inside the app bundle**, which is how a release ships — one artifact that
///    works on any Apple silicon Mac with no dependency on Apple Intelligence
///    being enabled, and nothing to download on first run.
/// 2. **A folder the user chose**, for anyone who wants a different or larger
///    model than the one that ships.
public enum ModelLocator {

    /// Files a usable MLX model directory must contain.
    static let requiredFiles = ["config.json", "tokenizer.json"]

    /// Where a bundled model lives inside the app.
    public static var bundledDirectory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appending(path: "Model")
        return isUsable(candidate) ? candidate : nil
    }

    /// Whether `directory` looks like an MLX model.
    ///
    /// Checked before loading so a missing or half-copied model produces a clear
    /// message rather than an error from inside the tensor loader.
    public static func isUsable(_ directory: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }

        for file in requiredFiles
        where !fm.fileExists(atPath: directory.appending(path: file).path) {
            return false
        }
        // Weights may be one file or sharded across several.
        let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// A human-readable name for a model directory.
    public static func displayName(for directory: URL) -> String {
        struct Config: Decodable { let modelType: String?
            enum CodingKeys: String, CodingKey { case modelType = "model_type" } }
        let config = directory.appending(path: "config.json")
        if let data = try? Data(contentsOf: config),
           let decoded = try? JSONDecoder().decode(Config.self, from: data),
           let type = decoded.modelType {
            return "\(directory.lastPathComponent) (\(type))"
        }
        return directory.lastPathComponent
    }

    /// Total size on disk, for the model-management UI.
    public static func size(of directory: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

#endif
