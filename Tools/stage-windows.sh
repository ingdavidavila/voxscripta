#!/bin/bash
# Gathers what a Windows build of the app needs beside voxscripta.exe, into
# build/windows-engine/, which flutter/app/windows/CMakeLists.txt copies from.
#
# Run after the three native builds, in this order:
#   Tools/build-ffmpeg.sh host     (from an MSYS2 UCRT64 shell)
#   Tools/build-engines.sh host    (CMAKE_GENERATOR=Ninja CC=clang-cl CXX=clang-cl)
#   swift build --product VoxScriptaFFI
# then this. It copies, it does not build, so a stale input stays stale: rerun
# the step that produced it.
#
# Not copied: the speech model. It is large and optional here; the app's
# install step adds build/models/ggml-*.bin as models/ when they are present,
# which is where ModelSearch looks beside the executable.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/windows-engine"
PRODUCTS="${VOXSCRIPTA_SWIFT_PRODUCTS:-$ROOT/build/win-swift/out/Products/Debug-windows-x86_64}"
FFMPEG_BIN="$ROOT/build/ffmpeg/host/prefix/bin"
SWIFT_RUNTIME="${VOXSCRIPTA_SWIFT_RUNTIME:-$(ls -d "$LOCALAPPDATA"/Programs/Swift/Runtimes/*/usr/bin 2>/dev/null | sort | tail -1)}"

[ -f "$PRODUCTS/VoxScriptaFFI.dll" ] || { echo "no VoxScriptaFFI.dll in $PRODUCTS; run swift build --product VoxScriptaFFI" >&2; exit 1; }
[ -d "$FFMPEG_BIN" ] || { echo "no FFmpeg DLLs in $FFMPEG_BIN; run Tools/build-ffmpeg.sh host" >&2; exit 1; }
[ -d "$SWIFT_RUNTIME" ] || { echo "no Swift runtime; set VOXSCRIPTA_SWIFT_RUNTIME" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$PRODUCTS/VoxScriptaFFI.dll" "$OUT/"
cp "$FFMPEG_BIN"/*.dll "$OUT/"
cp "$SWIFT_RUNTIME"/*.dll "$OUT/"
echo "staged $(ls "$OUT" | wc -l) files into $OUT"
