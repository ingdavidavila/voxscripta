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

mkdir -p "$OUT"
cd "$OUT"

CONFIGURE=(
    "$SRC/configure"
    --prefix="$PREFIX"
    --enable-shared --disable-static
    --disable-gpl --disable-nonfree --disable-version3
    --disable-programs --disable-doc --disable-avdevice --disable-avfilter
    --disable-postproc --disable-network --disable-iconv
    --disable-everything
    --enable-avformat --enable-avcodec --enable-avutil --enable-swresample
    --enable-protocol=file
    --enable-demuxer="$DEMUXERS"
    --enable-decoder="$DECODERS"
    --enable-parser="$PARSERS"
    --enable-pic
)

if [ "$ABI" != "host" ]; then
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
