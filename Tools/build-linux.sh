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
# voxscripta-cli is built as a product rather than a target, because the point
# of it is the link: a target builds objects, and objects proved nothing about
# whether FFmpeg, whisper.cpp, llama.cpp, miniaudio and SQLite are really there.
# They are, now — Tools/build-engines.sh linux-musl and
# Tools/build-ffmpeg.sh linux-musl build them, and SwiftPM compiles the other
# two from source.
#
# What cannot be built here is libVoxScriptaFFI.so, which the Flutter interface
# needs. The Static Linux SDK's own archives — libc++.a, libz.a — are compiled
# without -fPIC, because the SDK exists to produce one static executable rather
# than shared objects. Linking them into a .so fails with
# "relocation R_AARCH64_ADR_PREL_PG_HI21 cannot be used against symbol". That
# is a property of the SDK and not of this code, so the Flutter library has to
# be built on a real Linux host or in a container.
TARGETS=(VoxScriptaCore VoxScriptaExport VoxScriptaProject VoxScriptaLanguage
         VoxScriptaDSP VoxScriptaTranscription VoxScriptaBench VoxScriptaPipeline
         VoxScriptaFFI)

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

# The command line, linked. This is the check that matters: compiling says the
# Swift is portable, linking says the five C libraries underneath it really
# exist for this triple.
printf "  %-24s " "voxscripta-cli (link)"
if TOOLCHAINS="$TOOLCHAIN" swift build --package-path "$ROOT" \
    --swift-sdk "$SDK" --product voxscripta-cli >/dev/null 2>&1; then
    BIN="$ROOT/.build/out/Products/Debug-staticlinux-aarch64/voxscripta-cli"
    if [ -f "$BIN" ]; then
        echo "ok ($(du -h "$BIN" | cut -f1), $(file -b "$BIN" | cut -d, -f1-2))"
    else
        echo "ok (no binary found at the expected path)"
    fi
else
    echo "FAILED — build the C libraries first:"
    echo "      Tools/build-engines.sh linux-musl"
    echo "      Tools/build-ffmpeg.sh linux-musl"
    status=1
fi
exit $status
