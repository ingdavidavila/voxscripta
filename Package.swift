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
        .executable(name: "voxverba-cli", targets: ["voxverba-cli"]),
        .executable(name: "corpus-gen", targets: ["corpus-gen"]),
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

        // ── Tools ───────────────────────────────────────────────────────────
        .executableTarget(
            name: "voxverba-cli",
            dependencies: [
                "VoxVerbaCore", "VoxVerbaDSP", "VoxVerbaTranscription",
                "VoxVerbaLanguage", "VoxVerbaProject", "VoxVerbaExport", "VoxVerbaBench",
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "corpus-gen",
            dependencies: ["VoxVerbaCore", "VoxVerbaDSP"],
            swiftSettings: strict
        ),

        // ── Tests ───────────────────────────────────────────────────────────
        .testTarget(name: "VoxVerbaCoreTests", dependencies: ["VoxVerbaCore"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaDSPTests", dependencies: ["VoxVerbaDSP"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaTranscriptionTests",
                    dependencies: ["VoxVerbaTranscription"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaLanguageTests", dependencies: ["VoxVerbaLanguage"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaProjectTests", dependencies: ["VoxVerbaProject"], swiftSettings: strict),
        .testTarget(name: "VoxVerbaExportTests", dependencies: ["VoxVerbaExport"], swiftSettings: strict),
    ]
)
