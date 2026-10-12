#!/bin/bash
# Cross-compiles libvoxscripta for every Android ABI and checks the JNI contract.
#
# Run this after changing anything in core/ or android/jni/. It catches the two
# failures that a macOS build cannot: code that only compiles for 64-bit, and a
# JNI symbol name that has drifted away from its Kotlin declaration. A symbol
# mismatch is an UnsatisfiedLinkError at the first call rather than a build
# error, which is why it is checked here instead of being left to the app.
#
# Finds the NDK and CMake from an Android Studio SDK, a standalone NDK zip, or
# ANDROID_NDK_HOME / CMAKE if you want to pin them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Looked up rather than hardcoded, because this runs on two machines: one with
# a standalone NDK unzipped by hand, one with Android Studio's SDK.
find_ndk() {
    [ -n "${ANDROID_NDK_HOME:-}" ] && { echo "$ANDROID_NDK_HOME"; return; }
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
        [ -d "${sdk:-/nonexistent}/ndk" ] || continue
        # Highest installed version.
        local newest
        newest="$(ls -1 "$sdk/ndk" | sort -V | tail -1)"
        [ -n "$newest" ] && { echo "$sdk/ndk/$newest"; return; }
    done
    ls -d "$HOME"/Library/Android/android-ndk-* 2>/dev/null | sort -V | tail -1
}

find_cmake() {
    [ -n "${CMAKE:-}" ] && { echo "$CMAKE"; return; }
    command -v cmake 2>/dev/null && return
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk"; do
        [ -d "${sdk:-/nonexistent}/cmake" ] || continue
        local newest
        newest="$(ls -1 "$sdk/cmake" | sort -V | tail -1)"
        [ -x "$sdk/cmake/$newest/bin/cmake" ] && { echo "$sdk/cmake/$newest/bin/cmake"; return; }
    done
    echo "$HOME/Library/Python/3.9/bin/cmake"
}

NDK="$(find_ndk)"
CMAKE="$(find_cmake)"
API="${ANDROID_API:-28}"   # Android 9, about 95% of active devices

[ -n "$NDK" ] && [ -d "$NDK" ] || {
    echo "No NDK found. Install one in Android Studio, or set ANDROID_NDK_HOME." >&2; exit 1; }
[ -x "$CMAKE" ] || command -v "$CMAKE" >/dev/null || {
    echo "No cmake found. Install it in Android Studio, or set CMAKE." >&2; exit 1; }

echo "NDK:   $NDK"
echo "CMake: $CMAKE"
echo

# The prebuilt directory is named for the host, and is darwin-x86_64 even on
# Apple silicon because the NDK ships a universal binary under that name.
TOOLS="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
[ -d "$TOOLS" ] || TOOLS="$(ls -d "$NDK"/toolchains/llvm/prebuilt/*/bin 2>/dev/null | head -1)"
FAILED=0

for abi in arm64-v8a armeabi-v7a x86_64 x86; do
    out="$ROOT/build/android-$abi"
    rm -rf "$out"
    if "$CMAKE" -S "$ROOT/android" -B "$out" -G "Unix Makefiles" \
            -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
            -DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$API" \
            -DCMAKE_BUILD_TYPE=Release >/dev/null 2>"$out.log" \
        && "$CMAKE" --build "$out" >/dev/null 2>>"$out.log"; then
        lib="$(find "$out" -name libvoxscripta_jni.so | head -1)"
        printf "  %-12s %s\n" "$abi" "$(ls -lh "$lib" | awk '{print $5}')"
    else
        printf "  %-12s FAILED (see %s)\n" "$abi" "$out.log"
        FAILED=1
    fi
done

[ "$FAILED" -eq 0 ] || exit 1

# Every `external fun` in Kotlin must have a matching exported symbol.
LIB="$(find "$ROOT/build/android-arm64-v8a" -name libvoxscripta_jni.so | head -1)"
echo
echo "JNI contract"
# Dumped once into a variable rather than piped per lookup. `nm | grep -q`
# makes grep exit on its first match, which SIGPIPEs nm, and pipefail then
# reports the whole pipeline as failed — so every symbol looked missing while
# all of them were present. A verification script that cries wolf is worse than
# none.
SYMBOLS="$("$TOOLS/llvm-nm" --defined-only --extern-only "$LIB")"

MISSING=0
while read -r name; do
    [ -n "$name" ] || continue
    symbol="Java_dev_voxscripta_core_NativeTime_$name"
    if grep " T $symbol$" >/dev/null <<<"$SYMBOLS"; then
        printf "  %-28s bound\n" "$name"
    else
        printf "  %-28s MISSING from the library\n" "$name"
        MISSING=1
    fi
done < <(grep -oE 'external fun [a-zA-Z]+' "$ROOT/android/app/src/main/java/dev/voxscripta/core/NativeTime.kt" | awk '{print $3}')

[ "$MISSING" -eq 0 ] || { echo "A declaration has no symbol; that is an UnsatisfiedLinkError at runtime." >&2; exit 1; }

if "$TOOLS/llvm-readelf" -d "$LIB" > "$ROOT/build/android-dynamic.txt"; then :; fi
if grep "libc++_shared" >/dev/null < "$ROOT/build/android-dynamic.txt"; then
    echo
    echo "  note: libc++_shared.so is required — Gradle must package it."
fi
