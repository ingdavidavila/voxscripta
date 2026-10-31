#!/bin/bash
# Fetches the GGUF model the llama.cpp polish backend runs.
#
# Qwen2.5-1.5B-Instruct by default, because that is the model the MLX backend
# already bundles on Apple Silicon — same family, same size, so a difference
# between the two backends is a difference in the backend rather than in the
# model. Not in the repository: it is a gigabyte, and which quantization ships
# is a decision per platform.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/build/models"
FILE="$DEST/polish.gguf"
URL="${1:-https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf}"

if [ -f "$FILE" ]; then
    echo "already have $(basename "$FILE") ($(du -h "$FILE" | cut -f1))"
    exit 0
fi

mkdir -p "$DEST"
echo "fetching $(basename "$URL")"
curl -fL --progress-bar -o "$FILE.partial" "$URL"

# A GGUF file begins with the ASCII magic "GGUF", in that order on disk —
# unlike ggml's, which is a little-endian integer and reads backwards.
MAGIC="$(head -c 4 "$FILE.partial" | xxd -p | tr -d '\n')"
if [ "$MAGIC" != "47475546" ]; then
    rm -f "$FILE.partial"
    echo "that download is not a GGUF model (magic $MAGIC)" >&2
    exit 1
fi
mv "$FILE.partial" "$FILE"
echo "$(basename "$FILE")  $(du -h "$FILE" | cut -f1)"
