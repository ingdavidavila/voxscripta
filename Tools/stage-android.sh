#!/bin/bash
# Stages one Android ABI's native libraries where the Swift package reads them,
# and refuses to proceed if what is staged was built for something else.
#
#   Tools/stage-android.sh arm64-v8a        copy that ABI's build into place
#   Tools/stage-android.sh --check aarch64-unknown-linux-android26
#                                           verify what is staged, change nothing
#
# Why this exists. SwiftPM can select Android as a platform but not an ABI, and
# a manifest only sees the host, so Package.swift cannot know which of
# arm64-v8a / x86_64 it is being asked to link. The answer is to make the choice
# outside the manifest: this script copies the chosen ABI into fixed folders
#
#   build/engines/android/prefix      ggml, llama.cpp, whisper.cpp
#   build/ffmpeg/android/prefix       FFmpeg shared libraries
#   Sources/CFFmpeg/include/libav*    FFmpeg headers for the same build
#
# and Package.swift reads those. Switching ABIs by hand between builds is the
# hazard: a stale prefix silently builds the wrong ABI, producing a library that
# loads and then misbehaves, which is the worst failure available here.
#
# So every Android build records what it was built for, in <prefix>/.build-info
# (written by build-engines.sh and build-ffmpeg.sh): the ABI and the NDK
# revision. The NDK matters as well as the ABI because the FFmpeg headers
# (avconfig.h and friends) are generated per build, and a header set from a
# different NDK is the same class of silent mismatch.
#
# This script refuses, with a message that says which side disagrees, when
#   - a source build has no marker (built by an older script: rebuild it);
#   - a marker names a different ABI than the one requested;
#   - a marker names a different NDK than the one in ANDROID_NDK_HOME now.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGED_ENGINES="$ROOT/build/engines/android/prefix"
STAGED_FFMPEG="$ROOT/build/ffmpeg/android/prefix"
HEADERS="$ROOT/Sources/CFFmpeg/include"
LIBS=(libavcodec libavformat libavutil libswresample)

die() { echo "stage-android: $*" >&2; exit 1; }

# SwiftPM's triple -> the NDK's ABI name.
abi_for_triple() {
    case "$1" in
        aarch64-*) echo arm64-v8a ;;
        x86_64-*)  echo x86_64 ;;
        armv7*-*)  echo armeabi-v7a ;;
        i686-*)    echo x86 ;;
        *) die "do not know which Android ABI the triple '$1' means" ;;
    esac
}

current_ndk_revision() {
    local ndk="${ANDROID_NDK_HOME:-}"
    [ -n "$ndk" ] && [ -f "$ndk/source.properties" ] \
        || die "ANDROID_NDK_HOME is not set to an NDK (no source.properties found)"
    sed -n 's/^Pkg.Revision *= *//p' "$ndk/source.properties" | head -1
}

# Reads one key from a marker file; empty when the file or key is absent.
marker_value() { # file key
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -1
}

# Fails unless the marker in $1 (a prefix directory, a build tree, or a header
# folder) says it was built for $2 (ABI) with NDK revision $3. $4 names it.
verify_marker() { # marker_file abi ndk label
    local file="$1" abi="$2" ndk="$3" label="$4" got_abi got_ndk
    [ -f "$file" ] || die "$label has no .build-info ($file). It was built before builds recorded what they were for; rebuild it with Tools/build-engines.sh / build-ffmpeg.sh $abi."
    got_abi="$(marker_value "$file" abi)"
    got_ndk="$(marker_value "$file" ndk)"
    [ "$got_abi" = "$abi" ] \
        || die "$label was built for ABI '$got_abi' but '$abi' was requested. Refusing: it would link, then misbehave."
    [ "$got_ndk" = "$ndk" ] \
        || die "$label was built with NDK '$got_ndk' but the NDK now in use is '$ndk'. Refusing: the headers and libraries must come from one NDK."
}

[ $# -ge 1 ] || die "usage: stage-android.sh <abi> | --check <triple>"

NDK_REV="$(current_ndk_revision)"
[ -n "$NDK_REV" ] || die "could not read the NDK revision from \$ANDROID_NDK_HOME/source.properties"

if [ "$1" = "--check" ]; then
    [ $# -eq 2 ] || die "usage: stage-android.sh --check <triple>"
    ABI="$(abi_for_triple "$2")"
    verify_marker "$STAGED_ENGINES/.build-info" "$ABI" "$NDK_REV" "staged engines"
    verify_marker "$STAGED_FFMPEG/.build-info"  "$ABI" "$NDK_REV" "staged FFmpeg"
    verify_marker "$HEADERS/.build-info"        "$ABI" "$NDK_REV" "staged FFmpeg headers"
    echo "stage-android: staged files match $ABI with NDK $NDK_REV"
    exit 0
fi

ABI="$1"
case "$ABI" in arm64-v8a|x86_64|armeabi-v7a|x86) ;; *) die "unknown ABI '$ABI'" ;; esac

SRC_ENGINES="$ROOT/build/engines/$ABI/prefix"
SRC_FFMPEG="$ROOT/build/ffmpeg/$ABI/prefix"
[ -d "$SRC_ENGINES" ] || die "no engines build at $SRC_ENGINES. Run Tools/build-engines.sh $ABI"
[ -d "$SRC_FFMPEG" ]  || die "no FFmpeg build at $SRC_FFMPEG. Run Tools/build-ffmpeg.sh $ABI"

# Verify the sources first, so a refusal leaves whatever is already staged alone.
verify_marker "$SRC_ENGINES/.build-info" "$ABI" "$NDK_REV" "the $ABI engines build"
verify_marker "$SRC_FFMPEG/.build-info"  "$ABI" "$NDK_REV" "the $ABI FFmpeg build"

# :? so the shell aborts rather than running rm against a path built from an
# empty variable.
rm -rf "${STAGED_ENGINES:?}" "${STAGED_FFMPEG:?}"
mkdir -p "$STAGED_ENGINES" "$STAGED_FFMPEG"
cp -R "$SRC_ENGINES/." "$STAGED_ENGINES/"
cp -R "$SRC_FFMPEG/."  "$STAGED_FFMPEG/"

# The headers must come from the same FFmpeg build as the libraries.
for lib in "${LIBS[@]}"; do
    rm -rf "${HEADERS:?}/${lib:?}"
    cp -R "$SRC_FFMPEG/include/$lib" "$HEADERS/$lib"
done
cp "$SRC_FFMPEG/.build-info" "$HEADERS/.build-info"

verify_marker "$STAGED_ENGINES/.build-info" "$ABI" "$NDK_REV" "staged engines"
verify_marker "$STAGED_FFMPEG/.build-info"  "$ABI" "$NDK_REV" "staged FFmpeg"
verify_marker "$HEADERS/.build-info"        "$ABI" "$NDK_REV" "staged FFmpeg headers"
echo "stage-android: staged $ABI (NDK $NDK_REV) into build/engines/android, build/ffmpeg/android and Sources/CFFmpeg/include"
