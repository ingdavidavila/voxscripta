#!/bin/bash
# Cross-compiles the modules that build for Linux today, from a Mac.
#
# Needs the swift.org toolchain and the Static Linux SDK — Xcode's Swift and
# swift.org's are different builds of the same version, and the SDK's prebuilt
# modules will not load into the wrong one, which is a confusing error:
#
#   swift sdk install \
#     https://download.swift.org/swift-6.4.0-release/static-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
#     --checksum 47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${SWIFT_LINUX_SDK:-aarch64-swift-linux-musl}"
TOOLCHAIN="${SWIFT_TOOLCHAIN:-$(
    plutil -extract CFBundleIdentifier raw \
        ~/Library/Developer/Toolchains/swift-latest.xctoolchain/Info.plist 2>/dev/null || true)}"
[ -n "$TOOLCHAIN" ] || {
    echo "no swift.org toolchain in ~/Library/Developer/Toolchains" >&2
    echo "install one from swift.org, or set SWIFT_TOOLCHAIN" >&2
    exit 1
}

# What builds for Linux today: every module in the project.
#
# VoxScriptaPipeline used to be absent, and not because of its own code. It
# depended on VoxScriptaMLX, which is Apple Silicon only and pulls in a
# HuggingFace package that refuses to build against musl. Marking that
# dependency `.when(platforms: [.macOS, .iOS])` did not help — SwiftPM still
# built the target and its packages — so the dependency was inverted:
# PolishBackendResolver moved into VoxScriptaLanguage and the Apple apps now
# register MLX with it from above. Nothing above the language layer names MLX.
#
# voxscripta-cli is not listed, and the reason is different in kind. Every
# Swift file in it compiles for aarch64-linux-musl; what it cannot yet do is
# link, because the C libraries underneath — FFmpeg, whisper.cpp, llama.cpp,
# miniaudio, SQLite — have only ever been built for the Mac. Cross-building
# those is the next piece of work, and until it is done, listing the CLI here
# would report a Swift problem that does not exist. Check it by hand with:
#
#   TOOLCHAINS=$TOOLCHAIN swift build --swift-sdk $SDK --target voxscripta-cli
#
# and expect `ld.lld: unable to find library -lavformat`, not a type error.
TARGETS=(VoxScriptaCore VoxScriptaExport VoxScriptaProject VoxScriptaLanguage
         VoxScriptaDSP VoxScriptaTranscription VoxScriptaBench VoxScriptaPipeline)

status=0
for target in "${TARGETS[@]}"; do
    printf "  %-24s " "$target"
    if TOOLCHAINS="$TOOLCHAIN" swift build --package-path "$ROOT" \
        --swift-sdk "$SDK" --target "$target" >/dev/null 2>&1; then
        echo "ok"
    else
        echo "FAILED"
        status=1
    fi
done
exit $status
