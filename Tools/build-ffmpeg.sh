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
if [ "$ABI" = "linux-musl" ] || [ "$ABI" = "ios" ]; then
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
elif [ "$ABI" = "ios" ]; then
    # xcrun answers with whatever SDK the installed Xcode has, so this does
    # not pin a version the way a hardcoded path would.
    SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
    [ -n "$SDK" ] || { echo "no iPhoneOS SDK; install Xcode and its iOS platform" >&2; exit 1; }
    BIN="$(dirname "$(xcrun --sdk iphoneos --find clang)")"
    # -mios-version-min has to match the deployment target the Swift above it
    # is built with, or the objects link and then Swift rejects them.
    IOS_FLAGS="-arch arm64 -isysroot $SDK -mios-version-min=26.0"
    CONFIGURE+=(
        # FFmpeg calls every Apple platform darwin; the arch and the sysroot
        # are what make it a phone rather than the Mac running the build.
        --target-os=darwin --arch=arm64 --enable-cross-compile
        --cc="$BIN/clang" --cxx="$BIN/clang++"
        --ar="$BIN/ar" --nm="$BIN/nm" --ranlib="$BIN/ranlib" --strip="$BIN/strip"
        --extra-cflags="$IOS_FLAGS"
        --extra-ldflags="$IOS_FLAGS"
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

# Copy the installed headers next to the shim, which is where Swift looks for
# them: SwiftPM puts Sources/CFFmpeg/include on the search path for this target
# and for everything that imports it, and FFmpeg's own headers reference each
# other as <libavutil/...>, so the four directories have to sit side by side
# under one search path.
#
# Copied rather than symlinked, deliberately. These used to be four directory
# symlinks committed to git, which meant a checkout on Windows needed either
# Developer Mode or elevated privileges — a repository should not ask for that
# just to be cloned. They are build output, so the build produces them, and
# .gitignore keeps them out of history.
# Only for the ABIs SwiftPM will compile against here. There is one include
# directory for the whole package, so a cross-build must not leave its headers
# where the host build then reads them: a Mac that had built linux-musl last
# would be compiling against musl's avconfig.h. host and ios are both safe —
# on a Mac they are two Apple slices whose headers agree, and on Linux host is
# the native one.
HEADERS="$ROOT/Sources/CFFmpeg/include"
if [ "$ABI" != "host" ] && [ "$ABI" != "ios" ]; then
    echo "not staging headers for $ABI — they would displace the host's"
    HEADERS=""
fi
for lib in libavcodec libavformat libavutil libswresample; do
    [ -n "$HEADERS" ] || break
    # :? so the shell aborts rather than running rm against a path built from
    # an empty variable.
    rm -rf "${HEADERS:?}/${lib:?}"
    cp -R "$PREFIX/include/$lib" "$HEADERS/$lib"
done
[ -n "$HEADERS" ] && echo "staged headers into Sources/CFFmpeg/include"

echo "installed into $PREFIX"
find "$PREFIX/lib" \( -name '*.dylib' -o -name '*.so' \) -type f 2>/dev/null | sort | while read -r lib; do
    printf "  %-30s %s\n" "$(basename "$lib")" "$(du -h "$lib" | cut -f1)"
done
echo
echo "licence: LGPL v2.1 (--disable-gpl --disable-nonfree --disable-version3)"
