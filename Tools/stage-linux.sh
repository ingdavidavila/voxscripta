#!/bin/bash
# Gathers what a Linux build of the app needs in its lib/ folder, into
# build/linux-engine/, which flutter/app/linux/CMakeLists.txt installs from.
#
# Run after the native builds, in this order:
#   Tools/build-ffmpeg.sh host
#   Tools/build-engines.sh host
#   swift build -c release --product VoxScriptaFFI \
#       -Xlinker -lstdc++ -Xlinker -lgomp -Xlinker -rpath -Xlinker '$ORIGIN'
# then this. The rpath is what lets the engine find the libraries sitting next
# to it without LD_LIBRARY_PATH.
#
# Copied beside it: FFmpeg, the Swift runtime and the LLVM C++ runtime the
# engine libraries were built against. Left to the system: glibc, libstdc++,
# libgomp, zlib, bzip2. The runtime is not linked in statically because that
# build loads with an undefined Synchronization symbol.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/linux-engine"
ENGINE="${VOXSCRIPTA_ENGINE_SO:-$(find "$ROOT/.build" -name libVoxScriptaFFI.so -ipath '*release*linux*' 2>/dev/null | head -1)}"
FFMPEG_LIB="$ROOT/build/ffmpeg/host/prefix/lib"

[ -f "$ENGINE" ] || { echo "no libVoxScriptaFFI.so; run swift build -c release --product VoxScriptaFFI" >&2; exit 1; }
[ -d "$FFMPEG_LIB" ] || { echo "no FFmpeg libraries in $FFMPEG_LIB; run Tools/build-ffmpeg.sh host" >&2; exit 1; }

# A library built without the rpath loads here, where the build tree is, and
# nowhere else.
if command -v readelf >/dev/null 2>&1; then
    readelf -d "$ENGINE" | grep -E 'R(UN)?PATH' | grep -qF '$ORIGIN' \
        || { echo "$ENGINE has no \$ORIGIN rpath; see the build command above" >&2; exit 1; }
fi

# A debug engine contains the variable that fakes a subscription. Release
# builds compile it out, so finding its name means this must not be packaged.
if grep -aqF VOXSCRIPTA_ENTITLEMENT "$ENGINE"; then
    echo "$ENGINE is a debug build; rebuild with swift build -c release" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$ENGINE" "$OUT/"
# Under the name the loader asks for (libavformat.so.61), as a real file.
for lib in libavcodec libavformat libavutil libswresample; do
    versioned="$(ls "$FFMPEG_LIB"/$lib.so.[0-9]* 2>/dev/null | grep -E "$lib\.so\.[0-9]+$" | head -1)"
    [ -n "$versioned" ] || { echo "no $lib.so.N in $FFMPEG_LIB" >&2; exit 1; }
    cp -L "$versioned" "$OUT/"
done
# Whatever the loader finds in the Swift toolchain, and LLVM's C++ runtime,
# which a user's machine need not have.
ldd "$ENGINE" \
    | awk '$2 == "=>" && ($3 ~ /\/usr\/lib\/swift\// || $1 ~ /^lib(c\+\+|c\+\+abi|unwind)\.so/) { print $1, $3 }' \
    | while read -r name path; do cp -L "$path" "$OUT/$name"; done
ls "$OUT"/libswiftCore.so >/dev/null 2>&1 \
    || { echo "the Swift runtime was not found by ldd; was the engine built with --static-swift-stdlib?" >&2; exit 1; }
# Each library looks beside itself first, so the set that was shipped is the set
# that loads.
if command -v patchelf >/dev/null 2>&1; then
    for lib in "$OUT"/*.so*; do patchelf --set-rpath '$ORIGIN' "$lib"; done
fi
echo "staged $(ls "$OUT" | wc -l) files into $OUT"
