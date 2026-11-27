#!/bin/bash
# Gathers what a Windows build of the app needs beside voxscripta.exe, into
# build/windows-engine/, which flutter/app/windows/CMakeLists.txt copies from.
#
# Run after the three native builds, in this order:
#   Tools/build-ffmpeg.sh host     (from an MSYS2 UCRT64 shell)
#   Tools/build-engines.sh host    (CMAKE_GENERATOR=Ninja CC=clang-cl CXX=clang-cl)
#   swift build -c release --product VoxScriptaFFI
# then this. It copies, it does not build, so a stale input stays stale: rerun
# the step that produced it.
#
# Not copied: the speech model. It is large and optional here; the app's
# install step adds build/models/ggml-*.bin as models/ when they are present,
# which is where ModelSearch looks beside the executable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/windows-engine"
PRODUCTS="${VOXSCRIPTA_SWIFT_PRODUCTS:-$ROOT/build/win-swift/out/Products/Release-windows-x86_64}"
FFMPEG_BIN="$ROOT/build/ffmpeg/host/prefix/bin"
SWIFT_RUNTIME="${VOXSCRIPTA_SWIFT_RUNTIME:-$(ls -d "$LOCALAPPDATA"/Programs/Swift/Runtimes/*/usr/bin 2>/dev/null | sort | tail -1)}"

[ -f "$PRODUCTS/VoxScriptaFFI.dll" ] || { echo "no VoxScriptaFFI.dll in $PRODUCTS; run swift build -c release --product VoxScriptaFFI" >&2; exit 1; }
[ -d "$FFMPEG_BIN" ] || { echo "no FFmpeg DLLs in $FFMPEG_BIN; run Tools/build-ffmpeg.sh host" >&2; exit 1; }
[ -d "$SWIFT_RUNTIME" ] || { echo "no Swift runtime; set VOXSCRIPTA_SWIFT_RUNTIME" >&2; exit 1; }

VULKAN_DLL="${VOXSCRIPTA_SWIFT_PRODUCTS_VULKAN:-$ROOT/build/win-swift-vulkan/out/Products/Release-windows-x86_64}/VoxScriptaFFI.dll"

# A debug engine contains the variable that fakes a subscription. Release
# builds compile it out, so finding its name means this must not be packaged.
# Both engines are checked: the app loads the GPU one first.
for dll in "$PRODUCTS/VoxScriptaFFI.dll" "$VULKAN_DLL"; do
    if [ -f "$dll" ] && grep -aqF VOXSCRIPTA_ENTITLEMENT "$dll"; then
        echo "$dll is a debug build; rebuild it with swift build -c release" >&2
        exit 1
    fi
done

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$PRODUCTS/VoxScriptaFFI.dll" "$OUT/"
cp "$FFMPEG_BIN"/*.dll "$OUT/"
cp "$SWIFT_RUNTIME"/*.dll "$OUT/"
# The GPU engine, if it was built. The app tries it first and falls back to the
# one above, so leaving it out is a valid build.
if [ -f "$VULKAN_DLL" ]; then
    # Same ABI number, older code, would load without complaint.
    if [ "$VULKAN_DLL" -ot "$PRODUCTS/VoxScriptaFFI.dll" ]; then
        echo "warning: the Vulkan engine is older than the CPU one; rebuild it if the source changed" >&2
    fi
    cp "$VULKAN_DLL" "$OUT/VoxScriptaFFI-vulkan.dll"
else
    echo "no Vulkan engine; staging the CPU engine only"
fi
echo "staged $(ls "$OUT" | wc -l) files into $OUT"
