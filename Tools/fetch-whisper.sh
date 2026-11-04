#!/usr/bin/env bash
# Fetches the two things the Whisper engine needs and the repository does not
# contain: the pinned whisper.cpp source and the "small" model weights.
#
# This is the only network step in the Windows build; the app itself never
# touches the network. Re-running is safe: finished downloads are kept.
set -euo pipefail
cd "$(dirname "$0")/.."

WHISPER_TAG="v1.9.5"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
MODEL_BYTES=487601967   # ggml-small.bin as published; a short file means a broken download

if [ ! -f third_party/whisper.cpp/CMakeLists.txt ]; then
    mkdir -p third_party
    git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp third_party/whisper.cpp
    rm -rf third_party/whisper.cpp/.git
fi

mkdir -p models
size=$(stat -c %s models/ggml-small.bin 2>/dev/null || echo 0)
if [ "$size" != "$MODEL_BYTES" ]; then
    curl -L --fail -o models/ggml-small.bin "$MODEL_URL"
    size=$(stat -c %s models/ggml-small.bin)
    [ "$size" = "$MODEL_BYTES" ] || { echo "model is $size bytes, expected $MODEL_BYTES" >&2; exit 1; }
fi
echo "whisper.cpp $WHISPER_TAG and ggml-small.bin are in place."
