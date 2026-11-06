// swift-tools-version: 6.0
// VoxScripta — local-first transcription for Apple Silicon.

import PackageDescription
import Foundation

/// Every target compiles under the Swift 6 language mode. Strict concurrency is
/// therefore on by default and data-race safety is a compile error, not a warning.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

/// Where Tools/build-engines.sh leaves the native engines, and what to link.
///
/// Declared once because both C targets link the same set: llama.cpp and
/// whisper.cpp share a single ggml, installed into one prefix, so there is one
/// backend in the binary rather than two copies of the same symbols.
///
/// Unsafe flags are allowed because this is a root package and nothing depends
/// on it. If that ever changes, these become an xcframework.
let engineLinkerSettings: [LinkerSetting] = [
    // Per platform, because the two are built by the same script into
    // different prefixes: `Tools/build-engines.sh` for the Mac and
    // `Tools/build-engines.sh linux-musl` for Linux. One hardcoded `host`
    // path meant a Linux link looked for Mach-O archives.
    .unsafeFlags(["-Lbuild/engines/host/prefix/lib"],
                 .when(platforms: [.macOS, .iOS])),
    // Both Linux prefixes, because SwiftPM cannot tell them apart: a native
    // glibc build and a musl cross-build from a Mac are both `.linux`, and
    // they install to different directories. The linker takes whichever
    // exists; a missing -L is harmless. Without the host path a native Linux
    // build fails with 'cannot find -lwhisper'.
    .unsafeFlags(["-Lbuild/engines/linux-musl/prefix/lib",
                  "-Lbuild/engines/host/prefix/lib"],
                 .when(platforms: [.linux, .android])),
    .linkedLibrary("whisper"),
    .linkedLibrary("llama"),
    .linkedLibrary("ggml"),
    .linkedLibrary("ggml-base"),
    .linkedLibrary("ggml-cpu"),
    .linkedLibrary("c++"),
    .linkedLibrary("ggml-metal", .when(platforms: [.macOS, .iOS])),
    .linkedLibrary("ggml-blas", .when(platforms: [.macOS, .iOS])),
    .linkedFramework("Accelerate", .when(platforms: [.macOS, .iOS])),
    .linkedFramework("Metal", .when(platforms: [.macOS, .iOS])),
    .linkedFramework("MetalKit", .when(platforms: [.macOS, .iOS])),
    .linkedFramework("CoreFoundation", .when(platforms: [.macOS, .iOS])),
]

var products: [Product] = [
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
    // The interface as a library, so an Xcode app target can consume it.
    // SwiftPM cannot produce an .app for iOS, so the iOS app is a thin
    // shell around this; the macOS executable below is the same shell.
    .library(name: "VoxScriptaUI", targets: ["VoxScriptaUI"]),
    // Dynamic because Dart FFI opens a shared library at runtime:
    // libVoxScriptaFFI.dylib on a Mac, .so on Linux and Android, .dll on
    // Windows. Nothing links it statically.
    .library(name: "VoxScriptaFFI", type: .dynamic, targets: ["VoxScriptaFFI"]),
    .executable(name: "voxscripta-cli", targets: ["voxscripta-cli"]),
    .executable(name: "corpus-gen", targets: ["corpus-gen"]),
]

// The only external dependency in the project, and it buys independence from
// Apple Intelligence: a bundled model means the app works on any Apple
// silicon Mac regardless of whether the system LLM is available.
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
    // The tokenizer half. mlx-swift-lm defines the Tokenizer protocol but
    // leaves the implementation to the consumer, which is what its
    // #adaptHuggingFaceTokenizer macro exists to bridge.
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    // Already in the graph transitively; declared because this package
    // now uses it directly. It is CryptoKit's API on the platforms that
    // have no CryptoKit.
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
]

var targets: [Target] = [
    // ── The portable core (P1 of the React Native migration) ────────────
    // Plain C++20 with no dependencies, built here by SwiftPM and by CMake
    // for Android. The Swift modules above it are being ported into this
    // one target by target; until that finishes both implementations exist
    // and VoxScriptaCoreParityTests holds them to the same answers.

    // ggml, which whisper.cpp and llama.cpp share. One module, because the
    // declarations can only belong to one: see Sources/CGGML/include/CGGML.h.
    .target(
        name: "CGGML",
        path: "Sources/CGGML",
        sources: ["shim.c"],
        cSettings: [.headerSearchPath("include")],
        linkerSettings: engineLinkerSettings
    ),
    // whisper.cpp, reached through a header shim. The static libraries
    // come from Tools/build-whisper.sh rather than from SwiftPM, because
    // whisper.cpp no longer ships a Package.swift and because CMake is
    // what the Android NDK, Visual Studio and Linux all want anyway.
    .target(
        name: "CWhisper",
        dependencies: ["CGGML"],
        path: "Sources/CWhisper",
        sources: ["shim.c"],
        cSettings: [.headerSearchPath("include")],
        linkerSettings: engineLinkerSettings
    ),
    // llama.cpp, for POLISH off Apple's platforms. It shares the ggml that
    // Tools/build-engines.sh installs, so both engines are one copy of the
    // backend rather than two definitions of the same symbols.
    .target(
        name: "CLlama",
        dependencies: ["CGGML"],
        path: "Sources/CLlama",
        sources: ["shim.c"],
        cSettings: [.headerSearchPath("include")],
        linkerSettings: engineLinkerSettings
    ),
    // SQLite, compiled from the official amalgamation. Apple ships a
    // SQLite3 module and nothing else does — the static Linux SDK has no
    // libsqlite3 at all — so one known version is built from source for
    // every target. See Sources/CSQLite/README.md.
    .target(
        name: "CSQLite",
        path: "Sources/CSQLite",
        sources: ["sqlite3.c"],
        cSettings: [
            .headerSearchPath("include"),
            // What this project uses and nothing more: no loadable
            // extensions, which is also one less way into the process.
            .define("SQLITE_ENABLE_COLUMN_METADATA", to: "1"),
            .define("SQLITE_OMIT_LOAD_EXTENSION", to: "1"),
            .define("SQLITE_THREADSAFE", to: "1"),
            .define("SQLITE_DQS", to: "0"),
        ]
    ),
    // FFmpeg, for decoding where AVFoundation does not exist. Shared
    // libraries, built LGPL-only by Tools/build-ffmpeg.sh: the licence is
    // then satisfied by shipping them beside the binary, replaceable,
    // which static linking would not be.
    .target(
        name: "CFFmpeg",
        path: "Sources/CFFmpeg",
        sources: ["shim.c"],
        cSettings: [.headerSearchPath("include")],
        linkerSettings: [
            .unsafeFlags([
                "-Lbuild/ffmpeg/host/prefix/lib",
                // So a test or the app finds the dylibs without them
                // being installed system-wide. The Swift driver wants
                // -Xlinker pairs here; a -Wl, form is rejected outright.
                "-Xlinker", "-rpath", "-Xlinker",
                FileManager.default.currentDirectoryPath + "/build/ffmpeg/host/prefix/lib",
            ], .when(platforms: [.macOS, .iOS])),
            // No rpath on the static path: there is nothing to find at
            // run time because everything is in the binary.
            // Both, for the reason given on the engine settings above.
            .unsafeFlags(["-Lbuild/ffmpeg/linux-musl/prefix/lib",
                          "-Lbuild/ffmpeg/host/prefix/lib"],
                         .when(platforms: [.linux, .android])),
            // FFmpeg's own dependencies, which a shared build resolves for
            // itself and a static one hands to whoever links it. Both are
            // in the Static Linux SDK's sysroot; zlib is what the mov
            // demuxer uses for compressed headers.
            .linkedLibrary("z", .when(platforms: [.linux, .android])),
            .linkedLibrary("bz2", .when(platforms: [.linux, .android])),
            .linkedLibrary("avformat"),
            .linkedLibrary("avcodec"),
            .linkedLibrary("avutil"),
            .linkedLibrary("swresample"),
        ]
    ),
    // miniaudio, kept for device IO — recording, which is the backend
    // after this one. It decodes too, but FFmpeg does that now, and two
    // decode paths would be two behaviours to keep agreeing.
    .target(
        name: "CMiniaudio",
        path: "Sources/CMiniaudio",
        sources: ["miniaudio_impl.c"],
        cSettings: [.headerSearchPath("include")]
    ),
    .target(
        name: "VoxScriptaCoreCxx",
        path: "core",
        exclude: ["CMakeLists.txt", "tests"],
        sources: ["src"],
        publicHeadersPath: "include"
    ),

    // Named C++ specializations for the parity tests. Not shipped: no
    // product exposes it and nothing but the test target depends on it.
    .target(
        name: "VoxScriptaCxxShim",
        dependencies: ["VoxScriptaCoreCxx"],
        path: "Sources/VoxScriptaCxxShim",
        sources: ["src"],
        publicHeadersPath: "include"
    ),

    // ── Foundation layer ────────────────────────────────────────────────
    // No dependencies, by design. Every other module speaks this vocabulary.
    .target(name: "VoxScriptaCore", swiftSettings: strict),

    // ── Deterministic audio ─────────────────────────────────────────────
    .target(name: "VoxScriptaDSP",
            dependencies: ["VoxScriptaCore", "CFFmpeg", "CMiniaudio"],
            swiftSettings: strict),

    // ── Model-facing layers ─────────────────────────────────────────────
    .target(name: "VoxScriptaTranscription",
            dependencies: ["VoxScriptaCore", "VoxScriptaDSP", "CWhisper"],
            swiftSettings: strict),
    .target(name: "VoxScriptaLanguage", dependencies: ["VoxScriptaCore", "CLlama"],
            swiftSettings: strict),

    // ── Support layers ──────────────────────────────────────────────────
    .target(name: "VoxScriptaProject",
            dependencies: ["VoxScriptaCore", "CSQLite",
                           .product(name: "Crypto", package: "swift-crypto")],
            swiftSettings: strict),
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
                // Apple-only. On Linux mlx-swift tries to build its CUDA
                // backend and fails on a missing cuda.h, which takes the
                // whole package down rather than just this target — so
                // the dependency is gated rather than the target, and the
                // sources below are already behind `canImport(MLX)`.
                .product(name: "MLXLLM", package: "mlx-swift-lm",
                         condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm",
                         condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm",
                         condition: .when(platforms: [.macOS, .iOS])),
                .product(name: "Transformers", package: "swift-transformers",
                         condition: .when(platforms: [.macOS, .iOS])),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),

    // ── Orchestration ───────────────────────────────────────────────────
    // Ties the stages together and persists after each one. The only target
    // that knows the pipeline's shape; everything below it is independent.
    .target(name: "VoxScriptaPipeline",
            dependencies: ["VoxScriptaCore", "VoxScriptaDSP", "VoxScriptaTranscription",
                           "VoxScriptaLanguage", "VoxScriptaProject", "VoxScriptaBench"],
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
    .target(
        name: "VoxScriptaUI",
        // VoxScriptaMLX is declared here rather than inherited: the app is
        // the layer that ships the safetensors and registers them with
        // PolishBackendResolver, and it used to reach MLX only by accident,
        // through VoxScriptaPipeline, which no longer depends on it so that
        // the pipeline can cross-compile.
        dependencies: ["VoxScriptaCore", "VoxScriptaDSP", "VoxScriptaTranscription",
                       "VoxScriptaLanguage", "VoxScriptaProject", "VoxScriptaPipeline",
                       "VoxScriptaExport", "VoxScriptaMLX"],
        swiftSettings: strict),

    // The C ABI the Flutter interface calls. It depends on the pipeline and
    // the exporters and adds no rules of its own — deliberately, since a
    // rule that lived here would be a rule the SwiftUI interface could not
    // see.
    .target(
        name: "VoxScriptaFFI",
        dependencies: ["VoxScriptaCore", "VoxScriptaDSP", "VoxScriptaProject",
                       "VoxScriptaPipeline", "VoxScriptaExport"],
        swiftSettings: strict),

    // Nothing but @main. Everything it shows lives in VoxScriptaUI, which
    // the iOS app target consumes the same way.
    .executableTarget(
        name: "VoxScriptaApp",
        dependencies: ["VoxScriptaUI"],
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
    // Against the UI library rather than the executable: the executable
    // is now only @main, and a test bundle cannot link one anyway.
    .testTarget(name: "VoxScriptaAppTests",
                dependencies: ["VoxScriptaUI", "VoxScriptaPipeline"], swiftSettings: strict),
    .testTarget(name: "VoxScriptaFFITests",
                dependencies: ["VoxScriptaFFI", "VoxScriptaCore", "VoxScriptaProject",
                               "VoxScriptaTranscription", "VoxScriptaPipeline",
                               "VoxScriptaLanguage", "VoxScriptaDSP"],
                swiftSettings: strict),
    .testTarget(name: "VoxScriptaPipelineTests",
                dependencies: ["VoxScriptaPipeline", "VoxScriptaTestSupport"], swiftSettings: strict),
    // Holds the C++ port and the Swift original to the same answers.
    // Deleted, target by target, as each Swift module is retired.
    .testTarget(
        name: "VoxScriptaCoreParityTests",
        dependencies: ["VoxScriptaCore", "VoxScriptaCoreCxx", "VoxScriptaCxxShim",
                       "VoxScriptaDSP", "VoxScriptaExport", "VoxScriptaTranscription"],
        swiftSettings: [.swiftLanguageMode(.v6), .interoperabilityMode(.Cxx)]
    ),
    .testTarget(name: "VoxScriptaExportTests",
                dependencies: ["VoxScriptaExport", "VoxScriptaTestSupport"], swiftSettings: strict),
]

// ── The SwiftUI layer, which only Apple has ─────────────────────────────────
// VoxScriptaUI is twenty-one files of SwiftUI, StoreKit and
// AuthenticationServices, and the app target is its @main. There is nothing to
// guard file by file: the whole layer is Apple's, and every target below it
// already compiles elsewhere. Dropping them is what lets `swift test` run on
// Linux without stripping the package by hand.
//
// This reads the *host*, not the platform being built for, because that is all
// a manifest can see. It is therefore right for a native Linux build, which is
// the case that matters, and wrong for a cross-compile from a Mac — where the
// Static Linux SDK ships no swift-testing and so cannot build the test targets
// anyway.
#if !os(macOS) && !os(iOS)
let appleOnly: Set<String> = ["VoxScriptaUI", "VoxScriptaApp", "VoxScriptaAppTests"]
targets.removeAll { appleOnly.contains($0.name) }
products.removeAll { !Set($0.targets).isDisjoint(with: appleOnly) }
#endif

let package = Package(
    name: "VoxScripta",
    // iOS carries the same minimum as macOS because the app depends on
    // SpeechAnalyzer and FoundationModels, both of which arrived in the 26
    // releases. There is no older version this could run on.
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: products,
    dependencies: dependencies,
    targets: targets,
    cxxLanguageStandard: .cxx20
)
