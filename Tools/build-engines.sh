#!/bin/bash
# Builds the two portable engines — llama.cpp and whisper.cpp — as static
# libraries for the host, or for an Android ABI.
#
# They share one ggml. Both projects vendor their own copy, and linking both
# copies into one binary is a duplicate-symbol error, so llama.cpp is built and
# installed first and whisper.cpp is built against that install with
# WHISPER_USE_SYSTEM_GGML. One ggml in the binary, one set of backends, one
# place where a GPU backend is chosen.
#
# CMake rather than SwiftPM because neither project ships a Package.swift any
# more, and because CMake is what the other four platforms want anyway: the
# Android NDK, Visual Studio and a Linux box all speak it, and this repo builds
# core/ the same way.
#
#   Tools/build-engines.sh                 host (this machine)
#   Tools/build-engines.sh arm64-v8a       an Android ABI, needs the NDK
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_SRC="$ROOT/vendor/whisper.cpp"
LLAMA_SRC="$ROOT/vendor/llama.cpp"

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
OUT="$ROOT/build/engines/$ABI"
PREFIX="$OUT/prefix"

for src in "$WHISPER_SRC" "$LLAMA_SRC"; do
    [ -f "$src/CMakeLists.txt" ] || {
        echo "$(basename "$src") is empty — run: git submodule update --init --depth 1" >&2
        exit 1
    }
done

# Static, and nothing but the libraries: no servers, no command-line tools, no
# tests. Those would pull a main() and a socket layer into an app that must
# have neither.
common_flags() {
    echo "-DCMAKE_BUILD_TYPE=Release"
    echo "-DBUILD_SHARED_LIBS=OFF"
    echo "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
    echo "-DCMAKE_INSTALL_PREFIX=$PREFIX"
    if [ "$ABI" != "host" ]; then
        NDK="${ANDROID_NDK_HOME:-}"
        [ -n "$NDK" ] || NDK="$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | tail -1 || true)"
        [ -n "$NDK" ] || { echo "no NDK; set ANDROID_NDK_HOME" >&2; exit 1; }
        echo "-DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake"
        echo "-DANDROID_ABI=$ABI"
        echo "-DANDROID_PLATFORM=android-26"
        echo "-DGGML_OPENMP=OFF"
    fi
}

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# ── llama.cpp, which brings ggml with it ────────────────────────────────────
echo "building llama.cpp (and ggml) for $ABI"
# shellcheck disable=SC2046
"$CMAKE" -S "$LLAMA_SRC" -B "$OUT/llama" $(common_flags) \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_CURL=OFF
"$CMAKE" --build "$OUT/llama" --config Release -j"$JOBS"
"$CMAKE" --install "$OUT/llama" --config Release >/dev/null

# ── whisper.cpp, against the ggml that llama.cpp just installed ─────────────
echo "building whisper.cpp for $ABI, against the installed ggml"
# shellcheck disable=SC2046
"$CMAKE" -S "$WHISPER_SRC" -B "$OUT/whisper" $(common_flags) \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_USE_SYSTEM_GGML=ON \
    -DCMAKE_PREFIX_PATH="$PREFIX"
"$CMAKE" --build "$OUT/whisper" --config Release -j"$JOBS"
"$CMAKE" --install "$OUT/whisper" --config Release >/dev/null

echo
echo "installed into $PREFIX"
find "$PREFIX/lib" -name '*.a' 2>/dev/null | sort | while read -r lib; do
    printf "  %-34s %s\n" "$(basename "$lib")" "$(du -h "$lib" | cut -f1)"
done
