// swift-tools-version: 6.0
// VoxVerba — local-first transcription for Apple Silicon.

import PackageDescription

/// Every target compiles under the Swift 6 language mode. Strict concurrency is
/// therefore on by default and data-race safety is a compile error, not a warning.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "VoxVerba",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VoxVerbaCore", targets: ["VoxVerbaCore"]),
        .library(name: "VoxVerbaDSP", targets: ["VoxVerbaDSP"]),
        .library(name: "VoxVerbaTranscription", targets: ["VoxVerbaTranscription"]),
        .library(name: "VoxVerbaLanguage", targets: ["VoxVerbaLanguage"]),
        .library(name: "VoxVerbaProject", targets: ["VoxVerbaProject"]),
        .library(name: "VoxVerbaExport", targets: ["VoxVerbaExport"]),
        .library(name: "VoxVerbaBench", targets: ["VoxVerbaBench"]),
        .library(name: "VoxVerbaMLX", targets: ["VoxVerbaMLX"]),
        .library(name: "VoxVerbaPipeline", targets: ["VoxVerbaPipeline"]),
        .library(name: "VoxVerbaTestSupport", targets: ["VoxVerbaTestSupport"]),
        .executable(name: "VoxVerbaApp", targets: ["VoxVerbaApp"]),
        .executable(name: "voxverba-cli", targets: ["voxverba-cli"]),
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
        // ── Foundation layer ────────────────────────────────────────────────
        // No dependencies, by design. Every other module speaks this vocabulary.
        .target(name: "VoxVerbaCore", swiftSettings: strict),

        // ── Deterministic audio ─────────────────────────────────────────────
        .target(name: "VoxVerbaDSP", dependencies: ["VoxVerbaCore"], swiftSettings: strict),

        // ── Model-facing layers ─────────────────────────────────────────────
        .target(name: "VoxVerbaTranscription",
                dependencies: ["VoxVerbaCore", "VoxVerbaDSP"], swiftSettings: strict),
        .target(name: "VoxVerbaLanguage", dependencies: ["VoxVerbaCore"], swiftSettings: strict),

        // ── Support layers ──────────────────────────────────────────────────
        .target(name: "VoxVerbaProject", dependencies: ["VoxVerbaCore"], swiftSettings: strict),
        .target(name: "VoxVerbaExport", dependencies: ["VoxVerbaCore"], swiftSettings: strict),
        .target(name: "VoxVerbaBench", dependencies: ["VoxVerbaCore"], swiftSettings: strict),

        // ── Bundled language model ──────────────────────────────────────────
        // Kept in its own target so MLX does not reach the validator, the CLEAN
        // pass, or anything that must stay dependency-free and fast to compile.
        // Swift 6 mode, but without ExistentialAny: the tokenizer bridge comes
        // from mlx-swift-lm's #adaptHuggingFaceTokenizer macro, whose expansion
        // writes a bare `Tokenizer` existential. The warning is in generated code
        // that cannot be edited here, and the whole project builds with warnings
        // as errors, so the one upcoming feature is dropped for this target only.
        .target(name: "VoxVerbaMLX",
                dependencies: [
                    "VoxVerbaCore", "VoxVerbaLanguage",
                    .product(name: "MLXLLM", package: "mlx-swift-lm"),
                    .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                    .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                    .product(name: "Transformers", package: "swift-transformers"),
                ],
                swiftSettings: [.swiftLanguageMode(.v6)]),

        // ── Orchestration ───────────────────────────────────────────────────
        // Ties the stages together and persists after each one. The only target
        // that knows the pipeline's shape; everything below it is independent.
        .target(name: "VoxVerbaPipeline",
                dependencies: ["VoxVerbaCore", "VoxVerbaDSP", "VoxVerbaTranscription",
                               "VoxVerbaLanguage", "VoxVerbaMLX", "VoxVerbaProject",
                               "VoxVerbaBench"],
                swiftSettings: strict),

        // ── Test support ────────────────────────────────────────────────────
        // Deterministic corpus synthesis, shared by the test targets and by
        // corpus-gen. Because generation is reproducible, the synthetic fixtures
        // are built at test time rather than committed as binaries.
        .target(name: "VoxVerbaTestSupport",
                dependencies: ["VoxVerbaCore", "VoxVerbaTranscription", "VoxVerbaLanguage",
                               "VoxVerbaBench"],
                swiftSettings: strict),

        // ── Application ─────────────────────────────────────────────────────
        // A thin SwiftUI shell. All logic lives below it, so the app target holds
        // views, view models and nothing else.
        .executableTarget(
            name: "VoxVerbaApp",
            dependencies: ["VoxVerbaCore", "VoxVerbaDSP", "VoxVerbaTranscription",
                           "VoxVerbaLanguage", "VoxVerbaProject", "VoxVerbaPipeline",
                           "VoxVerbaExport"],
            swiftSettings: strict),

        // ── Tools ───────────────────────────────────────────────────────────
        .executableTarget(
            name: "voxverba-cli",
            dependencies: [
                "VoxVerbaCore", "VoxVerbaDSP", "VoxVerbaTranscription", "VoxVerbaLanguage",
                "VoxVerbaProject", "VoxVerbaPipeline", "VoxVerbaExport", "VoxVerbaBench",
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "corpus-gen",
            dependencies: ["VoxVerbaCore", "VoxVerbaDSP", "VoxVerbaTestSupport"],
            swiftSettings: strict
        ),

        // ── Tests ───────────────────────────────────────────────────────────
        .testTarget(name: "VoxVerbaCoreTests", dependencies: ["VoxVerbaCore"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaDSPTests",
                    dependencies: ["VoxVerbaDSP", "VoxVerbaTestSupport", "VoxVerbaBench"],
                    swiftSettings: strict),
        .testTarget(name: "VoxVerbaTranscriptionTests",
                    dependencies: ["VoxVerbaTranscription", "VoxVerbaDSP",
                                   "VoxVerbaTestSupport", "VoxVerbaBench"],
                    swiftSettings: strict),
        .testTarget(name: "VoxVerbaMLXTests",
                    dependencies: ["VoxVerbaMLX", "VoxVerbaLanguage"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "VoxVerbaLanguageTests",
                    dependencies: ["VoxVerbaLanguage", "VoxVerbaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaProjectTests",
                    dependencies: ["VoxVerbaProject", "VoxVerbaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaAppTests",
                    dependencies: ["VoxVerbaApp", "VoxVerbaPipeline"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaPipelineTests",
                    dependencies: ["VoxVerbaPipeline", "VoxVerbaTestSupport"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaExportTests",
                    dependencies: ["VoxVerbaExport", "VoxVerbaTestSupport"], swiftSettings: strict),
    ]
)
