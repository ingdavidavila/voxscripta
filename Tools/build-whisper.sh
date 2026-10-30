#!/bin/bash
# Builds whisper.cpp as a static library for the host, or for an Android ABI.
#
# CMake rather than SwiftPM because whisper.cpp stopped shipping a Package.swift,
# and because CMake is what the other four platforms want anyway: the Android
# NDK, Visual Studio and a Linux box all speak it, and this repo already builds
# core/ the same way. One build path for every target beats a special case for
# the Mac.
#
#   Tools/build-whisper.sh                 host (this machine)
#   Tools/build-whisper.sh arm64-v8a       an Android ABI, needs the NDK
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/whisper.cpp"
ABI="${1:-host}"
OUT="$ROOT/build/whisper/$ABI"

[ -f "$SRC/CMakeLists.txt" ] || {
    echo "vendor/whisper.cpp is empty — run: git submodule update --init --depth 1" >&2
    exit 1
}

# Static, no tools, no tests, no examples: this is linked into the engine, and
# nothing here should pull a server or a command line into the app.
COMMON=(
    -S "$SRC" -B "$OUT"
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_EXAMPLES=OFF
    -DWHISPER_BUILD_SERVER=OFF
)

if [ "$ABI" = "host" ]; then
    cmake "${COMMON[@]}"
else
    NDK="${ANDROID_NDK_HOME:-}"
    [ -n "$NDK" ] || NDK="$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | tail -1 || true)"
    [ -n "$NDK" ] || { echo "no NDK; set ANDROID_NDK_HOME" >&2; exit 1; }
    cmake "${COMMON[@]}" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM=android-26 \
        -DGGML_OPENMP=OFF
fi

cmake --build "$OUT" --config Release -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

echo
echo "built for $ABI:"
find "$OUT" -name 'libwhisper*.a' -o -name 'libggml*.a' | sort | while read -r lib; do
    printf "  %-52s %s\n" "${lib#$OUT/}" "$(du -h "$lib" | cut -f1)"
done
