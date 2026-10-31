#!/bin/bash
# Fetches a ggml Whisper model into build/models/.
#
# Kept out of the repository and out of the app bundle: the models run from
# 75 MB to 1.5 GB, and which one ships is a decision per platform, not a
# constant. Nothing downloads at runtime — this is a build-time fetch, and the
# app still has no network access of its own.
#
#   Tools/fetch-whisper-model.sh            base, multilingual (~148 MB)
#   Tools/fetch-whisper-model.sh small      better, slower (~488 MB)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-base}"
DEST="$ROOT/build/models"
FILE="$DEST/ggml-$NAME.bin"

if [ -f "$FILE" ]; then
    echo "already have $(basename "$FILE") ($(du -h "$FILE" | cut -f1))"
    exit 0
fi

mkdir -p "$DEST"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$NAME.bin"
echo "fetching ggml-$NAME.bin"
curl -fL --progress-bar -o "$FILE.partial" "$URL"

# A ggml model begins with the magic 0x67676d6c, written as a little-endian
# 32-bit integer — so on disk the bytes read 6c 6d 67 67, not "ggml". Checked
# because a truncated download or an HTML error page would otherwise fail much
# later, inside the model loader, with nothing useful to say.
# `xxd -p` rather than `od`, which groups and swaps bytes depending on the
# platform — it reported "lmgg" for a file that begins "ggml".
MAGIC="$(head -c 4 "$FILE.partial" | xxd -p | tr -d '\n')"
if [ "$MAGIC" != "6c6d6767" ]; then
    rm -f "$FILE.partial"
    echo "that download is not a ggml model (magic $MAGIC)" >&2
    exit 1
fi
mv "$FILE.partial" "$FILE"
echo "$(basename "$FILE")  $(du -h "$FILE" | cut -f1)"
