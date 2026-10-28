// swift-tools-version: 6.0
// VoxScripta — local-first transcription for Apple Silicon.

import PackageDescription

/// Every target compiles under the Swift 6 language mode. Strict concurrency is
/// therefore on by default and data-race safety is a compile error, not a warning.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "VoxScripta",
    // iOS carries the same minimum as macOS because the app depends on
    // SpeechAnalyzer and FoundationModels, both of which arrived in the 26
    // releases. There is no older version this could run on.
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "VoxScriptaCore", targets: ["VoxScriptaCore"]),
        .library(name: "VoxScriptaCoreCxx", targets: ["VoxScriptaCoreCxx"]),
        .library(name: "VoxScriptaDSP", targets: ["VoxScriptaDSP"]),
        .library(name: "VoxScriptaTranscription", targets: ["VoxScriptaTranscription"]),
        .library(name: "VoxScriptaLanguage", targets: ["VoxScriptaLanguage"]),
        .library(name: "VoxScriptaProject", targets: ["VoxScriptaProject"]),
        .library(name: "VoxScriptaExport", targets: ["VoxScriptaExport"]),
        .library(name: "VoxScriptaBench", targets: ["VoxScriptaBench"]),
        .library(name: "VoxScriptaMLX", targets: ["VoxScriptaMLX"]),
        .library(name: "VoxScriptaPipeline", targets: ["VoxScriptaPipeline"]),
        .library(name: "VoxScriptaTestSupport", targets: ["VoxScriptaTestSupport"]),
        .executable(name: "VoxScriptaApp", targets: ["VoxScriptaApp"]),
        .executable(name: "voxscripta-cli", targets: ["voxscripta-cli"]),
        .executable(name: "corpus-gen", targets: ["corpus-gen"]),
    ],
    // The only external dependency in the project, and it buys independence from
    // Apple Intelligence: a bundled model means the app works on any Apple
    // silicon Mac regardless of whether the system LLM is available.
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        // The tokenizer half. mlx-swift-lm defines the Tokenizer protocol but
        // leaves the implementation to the consumer, which is what its
        // #adaptHuggingFaceTokenizer macro exists to bridge.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // ── The portable core (P1 of the React Native migration) ────────────
        // Plain C++20 with no dependencies, built here by SwiftPM and by CMake
        // for Android. The Swift modules above it are being ported into this
        // one target by target; until that finishes both implementations exist
        // and VoxScriptaCoreParityTests holds them to the same answers.
        .target(
            name: "VoxScriptaCoreCxx",
            path: "core",
            exclude: ["CMakeLists.txt", "tests"],
            sources: ["src"],
            publicHeadersPath: "include"
        ),

        // ── Foundation layer ────────────────────────────────────────────────
        // No dependencies, by design. Every other module speaks this vocabulary.
        .target(name: "VoxScriptaCore", swiftSettings: strict),

        // ── Deterministic audio ─────────────────────────────────────────────
        .target(name: "VoxScriptaDSP", dependencies: ["VoxScriptaCore"], swiftSettings: strict),

        // ── Model-facing layers ─────────────────────────────────────────────
        .target(name: "VoxScriptaTranscription",
                dependencies: ["VoxScriptaCore", "VoxScriptaDSP"], swiftSettings: strict),
        .target(name: "VoxScriptaLanguage", dependencies: ["VoxScriptaCore"], swiftSettings: strict),

        // ── Support layers ──────────────────────────────────────────────────
        .target(name: "VoxScriptaProject", dependencies: ["VoxScriptaCore"], swiftSettings: strict),
        .target(name: "VoxScriptaExport", dependencies: ["VoxScriptaCore"], swiftSettings: strict),
        .target(name: "VoxScriptaBench", dependencies: ["VoxScriptaCore"], swiftSettings: strict),

        // ── Bundled language model ──────────────────────────────────────────
        // Kept in its own target so MLX does not reach the validator, the CLEAN
        // pass, or anything that must stay dependency-free and fast to compile.
        // Swift 6 mode, but without ExistentialAny: the tokenizer bridge comes
        // from mlx-swift-lm's #adaptHuggingFaceTokenizer macro, whose expansion
        // writes a bare `Tokenizer` existential. The warning is in generated code
        // that cannot be edited here, and the whole project builds with warnings
        // as errors, so the one upcoming feature is dropped for this target only.
        .target(name: "VoxScriptaMLX",
                dependencies: [
                    "VoxScriptaCore", "VoxScriptaLanguage",
                    .product(name: "MLXLLM", package: "mlx-swift-lm"),
                    .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                    .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                    .product(name: "Transformers", package: "swift-transformers"),
                ],
                swiftSettings: [.swiftLanguageMode(.v6)]),

        // ── Orchestration ───────────────────────────────────────────────────
        // Ties the stages together and persists after each one. The only target
        // that knows the pipeline's shape; everything below it is independent.
        .target(name: "VoxScriptaPipeline",
                dependencies: ["VoxScriptaCore", "VoxScriptaDSP", "VoxScriptaTranscription",
                               "VoxScriptaLanguage", "VoxScriptaMLX", "VoxScriptaProject",
                               "VoxScriptaBench"],
                swiftSettings: strict),

        // ── Test support ────────────────────────────────────────────────────
        // Deterministic corpus synthesis, shared by the test targets and by
        // corpus-gen. Because generation is reproducible, the synthetic fixtures
        // are built at test time rather than committed as binaries.
        .target(name: "VoxScriptaTestSupport",
                dependencies: ["VoxScriptaCore", "VoxScriptaTranscription", "VoxScriptaLanguage",
                               "VoxScriptaBench"],
                swiftSettings: strict),

        // ── Application ─────────────────────────────────────────────────────
        // A thin SwiftUI shell. All logic lives below it, so the app target holds
        // views, view models and nothing else.
        .executableTarget(
            name: "VoxScriptaApp",
            dependencies: ["VoxScriptaCore", "VoxScriptaDSP", "VoxScriptaTranscription",
                           "VoxScriptaLanguage", "VoxScriptaProject", "VoxScriptaPipeline",
                           "VoxScriptaExport"],
            swiftSettings: strict),

        // ── Tools ───────────────────────────────────────────────────────────
        .executableTarget(
            name: "voxscripta-cli",
            dependencies: [
                "VoxScriptaCore", "VoxScriptaDSP", "VoxScriptaTranscription", "VoxScriptaLanguage",
                "VoxScriptaProject", "VoxScriptaPipeline", "VoxScriptaExport", "VoxScriptaBench",
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "corpus-gen",
            dependencies: ["VoxScriptaCore", "VoxScriptaDSP", "VoxScriptaTestSupport"],
            swiftSettings: strict
        ),

        // ── Tests ───────────────────────────────────────────────────────────
        .testTarget(name: "VoxScriptaCoreTests", dependencies: ["VoxScriptaCore"], swiftSettings: strict),
        .testTarget(name: "VoxScriptaDSPTests",
                    dependencies: ["VoxScriptaDSP", "VoxScriptaTestSupport", "VoxScriptaBench"],
                    swiftSettings: strict),
        .testTarget(name: "VoxScriptaTranscriptionTests",
                    dependencies: ["VoxScriptaTranscription", "VoxScriptaDSP",
                                   "VoxScriptaTestSupport", "VoxScriptaBench"],
                    swiftSettings: strict),
        .testTarget(name: "VoxScriptaMLXTests",
                    dependencies: ["VoxScriptaMLX", "VoxScriptaLanguage"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "VoxScriptaLanguageTests",
                    dependencies: ["VoxScriptaLanguage", "VoxScriptaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxScriptaProjectTests",
                    dependencies: ["VoxScriptaProject", "VoxScriptaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxScriptaAppTests",
                    dependencies: ["VoxScriptaApp", "VoxScriptaPipeline"], swiftSettings: strict),
        .testTarget(name: "VoxScriptaPipelineTests",
                    dependencies: ["VoxScriptaPipeline", "VoxScriptaTestSupport"], swiftSettings: strict),
        // Holds the C++ port and the Swift original to the same answers.
        // Deleted, target by target, as each Swift module is retired.
        .testTarget(
            name: "VoxScriptaCoreParityTests",
            dependencies: ["VoxScriptaCore", "VoxScriptaCoreCxx"],
            swiftSettings: [.swiftLanguageMode(.v6), .interoperabilityMode(.Cxx)]
        ),
        .testTarget(name: "VoxScriptaExportTests",
                    dependencies: ["VoxScriptaExport", "VoxScriptaTestSupport"], swiftSettings: strict),
    ],
    cxxLanguageStandard: .cxx20
)
