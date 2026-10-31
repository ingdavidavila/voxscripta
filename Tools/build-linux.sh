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

# What builds for Linux today. VoxScriptaDSP is absent on purpose: it uses
# Accelerate for the FFT behind the spectral features, and a portable
# replacement has to be measured against the Accelerate one before anything
# depends on it. Everything downstream of DSP — Pipeline, Transcription, the
# CLI — waits on that.
TARGETS=(VoxScriptaCore VoxScriptaExport VoxScriptaProject VoxScriptaLanguage)

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
