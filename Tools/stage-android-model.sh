#!/bin/bash
# Puts the speech model where the Android asset pack will pick it up.
#
# The model is delivered by Google Play as an install-time asset pack
# (flutter/app/android/speech_model), and the pack's content is deliberately not in
# the repository: it is hundreds of megabytes and which model ships is a decision.
# This stages one into the pack's assets directory, fetching it first if it is not
# in build/models, and checks it is a real ggml model before letting a bundle be
# built from it.
#
#   Tools/stage-android-model.sh            small (~488 MB), the default shipped
#   Tools/stage-android-model.sh base       base (~148 MB), for a lighter test
#
# Only one model is staged at a time, so switching replaces the old one rather
# than shipping both. The app prefers small and falls back to base, and a pack
# holding both would be a gigabyte nobody asked for.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-small}"
SOURCE="$ROOT/build/models/ggml-$NAME.bin"
PACK="$ROOT/flutter/app/android/speech_model/src/main/assets/models"

[ -f "$SOURCE" ] || "$ROOT/Tools/fetch-whisper-model.sh" "$NAME"

# ggml's magic 0x67676d6c is written little-endian, so the bytes read 6c 6d 67 67.
MAGIC="$(head -c 4 "$SOURCE" | od -An -tx1 | tr -d ' \n')"
if [ "$MAGIC" != "6c6d6767" ]; then
    echo "$SOURCE is not a ggml model (magic $MAGIC)" >&2
    exit 1
fi

mkdir -p "$PACK"
rm -f "$PACK"/ggml-*.bin
cp "$SOURCE" "$PACK/ggml-$NAME.bin"
echo "staged ggml-$NAME.bin ($(du -h "$PACK/ggml-$NAME.bin" | cut -f1)) in the speech model pack"
