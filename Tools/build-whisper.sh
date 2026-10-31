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

# Looked up rather than assumed, the same way Tools/verify-android-core.sh does
# it: this has to run on a Mac with CMake installed by hand, and on a Windows or
# Linux box where Android Studio supplies it.
find_cmake() {
    command -v cmake 2>/dev/null && return || true
    [ -x /Applications/CMake.app/Contents/bin/cmake ] \
        && { echo /Applications/CMake.app/Contents/bin/cmake; return; }
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" \
               "$LOCALAPPDATA/Android/Sdk" "$HOME/Android/Sdk"; do
        [ -n "$sdk" ] && [ -d "$sdk/cmake" ] || continue
        newest="$(ls -1 "$sdk/cmake" | sort -V | tail -1)"
        [ -x "$sdk/cmake/$newest/bin/cmake" ] && { echo "$sdk/cmake/$newest/bin/cmake"; return; }
    done
    return 1
}
CMAKE="${CMAKE:-$(find_cmake || true)}"
[ -n "$CMAKE" ] || {
    echo "no cmake found. Install it, or set CMAKE to its path." >&2
    exit 1
}
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
    "$CMAKE" "${COMMON[@]}"
else
    NDK="${ANDROID_NDK_HOME:-}"
    [ -n "$NDK" ] || NDK="$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | tail -1 || true)"
    [ -n "$NDK" ] || { echo "no NDK; set ANDROID_NDK_HOME" >&2; exit 1; }
    "$CMAKE" "${COMMON[@]}" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM=android-26 \
        -DGGML_OPENMP=OFF
fi

"$CMAKE" --build "$OUT" --config Release -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

echo
echo "built for $ABI:"
find "$OUT" -name 'libwhisper*.a' -o -name 'libggml*.a' | sort | while read -r lib; do
    printf "  %-52s %s\n" "${lib#$OUT/}" "$(du -h "$lib" | cut -f1)"
done
