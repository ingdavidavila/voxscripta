#!/bin/bash
# Builds a minimal FFmpeg for decoding, as shared libraries.
#
# Shared, and --disable-gpl --disable-nonfree, so the result is LGPL v2.1 and
# nothing else. That combination is what makes FFmpeg usable in an app whose
# own source is not published: the licence is satisfied by shipping the
# libraries alongside the binary, where they can be replaced. Static linking
# would also be possible but obliges us to hand out object files for relinking,
# which is a worse deal for no benefit.
#
# Cut down hard. The full build is tens of megabytes of codecs for formats
# nobody will hand a transcription app; this enables the containers and
# decoders AVFoundation reads and nothing else, which is the point — parity
# with the Apple path, not a media player.
#
#   Tools/build-ffmpeg.sh                host
#   Tools/build-ffmpeg.sh arm64-v8a      an Android ABI, needs the NDK
#   Tools/build-ffmpeg.sh linux-musl     aarch64 Linux, from the Static SDK
#
# The linux-musl target is **static**, and that is a licence difference rather
# than a build preference. The Swift Static Linux SDK contains no shared
# objects at all — 52 archives and not one .so — because its whole purpose is
# producing a single static executable. So a shared FFmpeg cannot be linked
# there, and LGPL v2.1 §6 then asks for something more than shipping the
# libraries: a static link obliges us to make the application's object files
# available so that someone can relink it against their own FFmpeg. That is a
# real obligation before anything is distributed for Linux, and it is recorded
# here rather than discovered.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/ffmpeg"
ABI="${1:-host}"
OUT="$ROOT/build/ffmpeg/$ABI"
PREFIX="$OUT/prefix"

[ -f "$SRC/configure" ] || {
    echo "vendor/ffmpeg is empty — run: git submodule update --init --depth 1" >&2
    exit 1
}

# What a transcription app is actually handed. The mov demuxer covers mp4, m4a
# and mov together, which is the gap miniaudio left and the reason this exists.
DEMUXERS="mov,wav,mp3,flac,aiff,ogg,matroska,caf,aac,w64,au"
DECODERS="aac,aac_latm,alac,mp3,mp3float,flac,vorbis,opus,\
pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le,pcm_s16be,pcm_s24be,pcm_u8,pcm_alaw,pcm_mulaw"
PARSERS="aac,aac_latm,mpegaudio,flac,vorbis,opus"
# Writing, not just reading. The portable recorder muxes a fragmented m4a with
# exactly the flags the Apple one uses, so a recording made on Android or
# Windows is the same kind of file as one made on a Mac — and survives a crash
# the same way, because the index is written as it goes rather than at the end.
# FFmpeg's own AAC encoder, which is in-tree and LGPL; libfdk would not be.
ENCODERS="aac,pcm_s16le,pcm_f32le,flac"
MUXERS="mov,ipod,mp4,wav,flac"

mkdir -p "$OUT"
cd "$OUT"

# Shared where it is possible, static where it is not. See the note at the top
# about what that costs.
if [ "$ABI" = "linux-musl" ]; then
    LINKAGE=(--disable-shared --enable-static)
else
    LINKAGE=(--enable-shared --disable-static)
fi

CONFIGURE=(
    "$SRC/configure"
    --prefix="$PREFIX"
    "${LINKAGE[@]}"
    --disable-gpl --disable-nonfree --disable-version3
    --disable-programs --disable-doc --disable-avdevice --disable-avfilter
    --disable-postproc --disable-network --disable-iconv
    --disable-everything
    --enable-avformat --enable-avcodec --enable-avutil --enable-swresample
    --enable-protocol=file
    --enable-demuxer="$DEMUXERS"
    --enable-decoder="$DECODERS"
    --enable-parser="$PARSERS"
    --enable-encoder="$ENCODERS"
    --enable-muxer="$MUXERS"
    --enable-pic
)

if [ "$ABI" = "linux-musl" ]; then
    # The same clang and sysroot SwiftPM uses for this triple, for the same
    # reason the CMake toolchain does: the C and the Swift that calls it have
    # to agree about libc.
    SYSROOT="${SWIFT_LINUX_SYSROOT:-}"
    [ -n "$SYSROOT" ] || SYSROOT="$(ls -d "$HOME"/.swiftpm/swift-sdks/*.artifactbundle/*/swift-linux-musl/musl-*.sdk/aarch64 2>/dev/null | sort | tail -1)"
    [ -n "$SYSROOT" ] && [ -f "$SYSROOT/usr/lib/libc.a" ] || {
        echo "no musl sysroot; install the Static Linux SDK or set SWIFT_LINUX_SYSROOT" >&2
        exit 1
    }
    BIN="${SWIFT_CLANG_BIN:-$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin}"
    [ -x "$BIN/clang" ] || {
        echo "no clang at $BIN; install a swift.org toolchain or set SWIFT_CLANG_BIN" >&2
        exit 1
    }
    TRIPLE=aarch64-unknown-linux-musl
    # clang defaults to GCC's runtime — libgcc, crtbeginS.o — and a musl/LLVM
    # sysroot has none of it. It ships compiler-rt and libunwind instead, under
    # its own resource directory, so all three have to be named. Without them
    # FFmpeg's configure fails at its very first link test with
    # "unable to find library -lgcc", which says nothing about the real cause.
    MUSL_FLAGS="--target=$TRIPLE --sysroot=$SYSROOT"
    MUSL_FLAGS="$MUSL_FLAGS -resource-dir=$SYSROOT/usr/lib/swift/clang"
    CONFIGURE+=(
        --target-os=linux --arch=aarch64 --enable-cross-compile
        --cc="$BIN/clang" --cxx="$BIN/clang++"
        --ar="$BIN/llvm-ar" --nm="$BIN/llvm-nm" --ranlib="$BIN/llvm-ranlib"
        --strip="$BIN/llvm-strip"
        --extra-cflags="$MUSL_FLAGS"
        --extra-ldflags="$MUSL_FLAGS -rtlib=compiler-rt -unwindlib=libunwind -static -fuse-ld=lld"
    )
elif [ "$ABI" != "host" ]; then
    NDK="${ANDROID_NDK_HOME:-}"
    [ -n "$NDK" ] || NDK="$(ls -d "$HOME/Library/Android/sdk/ndk/"* 2>/dev/null | tail -1 || true)"
    [ -n "$NDK" ] || { echo "no NDK; set ANDROID_NDK_HOME" >&2; exit 1; }
    HOST_TAG="$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64"
    BIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin"
    case "$ABI" in
        arm64-v8a)   ARCH=aarch64; TRIPLE=aarch64-linux-android ;;
        armeabi-v7a) ARCH=arm;     TRIPLE=armv7a-linux-androideabi ;;
        x86_64)      ARCH=x86_64;  TRIPLE=x86_64-linux-android ;;
        x86)         ARCH=x86;     TRIPLE=i686-linux-android ;;
        *) echo "unknown ABI $ABI" >&2; exit 1 ;;
    esac
    CONFIGURE+=(
        --target-os=android --arch="$ARCH" --enable-cross-compile
        --cc="$BIN/${TRIPLE}26-clang" --cxx="$BIN/${TRIPLE}26-clang++"
        --ar="$BIN/llvm-ar" --nm="$BIN/llvm-nm" --ranlib="$BIN/llvm-ranlib"
        --strip="$BIN/llvm-strip"
    )
fi

"${CONFIGURE[@]}" >"$OUT/configure.log" 2>&1 || {
    echo "configure failed; last lines of $OUT/configure.log:" >&2
    tail -20 "$OUT/configure.log" >&2
    exit 1
}
make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" >"$OUT/build.log" 2>&1 || {
    echo "build failed; last lines of $OUT/build.log:" >&2
    tail -20 "$OUT/build.log" >&2
    exit 1
}
make install >/dev/null

echo "installed into $PREFIX"
find "$PREFIX/lib" \( -name '*.dylib' -o -name '*.so' \) -type f 2>/dev/null | sort | while read -r lib; do
    printf "  %-30s %s\n" "$(basename "$lib")" "$(du -h "$lib" | cut -f1)"
done
echo
echo "licence: LGPL v2.1 (--disable-gpl --disable-nonfree --disable-version3)"
