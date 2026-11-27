#!/bin/bash
# Fetches the GGUF models the llama.cpp polish backend runs, and verifies them.
#
# Qwen2.5-Instruct in q4_k_m at two sizes, because that is the model the MLX
# backend already bundles on Apple Silicon — same family, same quantization, so
# a difference between the two backends is a difference in the backend rather
# than in the model. Not in the repository: together they are a gigabyte and a
# half, and which one ships is a decision per platform.
#
#   desktop   polish.gguf        1.5B   macOS, Windows, Linux
#   phone     polish-0.5b.gguf   0.5B   iOS, Android
#
# `Tools/stage-polish-model.sh` puts them where each platform's build looks.
#
# ## Why the sizes and hashes are pinned here
#
# The 0.5B had no recorded source at all. `stage-polish-model.sh phone` named a
# file that nothing in the repository could produce, and every message in the
# codebase that says "run Tools/fetch-polish-model.sh" was wrong for iOS and
# Android — the script only ever fetched the 1.5B. The Windows session asked
# where the file came from and the repository had no answer, which is the kind
# of gap §38 is about: a staging step that reads as finished and cannot run.
#
# So each file is now identified by what it is rather than by where it came
# from. A URL can be redirected and a repository can be re-uploaded; the hash
# cannot. Both hashes were read off the files this project measured POLISH
# with. How far each was checked against the remote differs, and saying so is
# cheaper than anyone re-deriving it:
#
#   0.5B   downloaded again in full and hashed: byte-identical.
#   1.5B   size confirmed against the remote (1,117,320,736 bytes); the hash is
#          of the local file this script's own URL produced. Not re-downloaded.
#
# Either way the gate does its job on the next fetch: a remote that has changed
# since fails loudly here instead of becoming a model nobody can account for.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/build/models"
BASE="https://huggingface.co/Qwen"

# name | url | bytes | sha256
DESKTOP="polish.gguf
$BASE/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf
1117320736
6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"

PHONE="polish-0.5b.gguf
$BASE/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
491400032
74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"

usage() {
    cat >&2 <<'USAGE'
usage: Tools/fetch-polish-model.sh [desktop|phone|both]

  desktop   polish.gguf       1.5B, 1,117,320,736 bytes
  phone     polish-0.5b.gguf  0.5B,   491,400,032 bytes
  both      the default

Verifies size and sha256 on arrival, and re-verifies a file already present.
USAGE
    exit 2
}

sha256() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else sha256sum "$1" | cut -d' ' -f1
    fi
}

size_of() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }

fetch() {
    local name url bytes want file actual
    name="$(echo "$1" | sed -n 1p)"
    url="$(echo "$1" | sed -n 2p)"
    bytes="$(echo "$1" | sed -n 3p)"
    want="$(echo "$1" | sed -n 4p)"
    file="$DEST/$name"

    # A file already here is verified rather than trusted. The old script
    # checked only that something existed at the path, so a truncated download
    # was indistinguishable from a model — and llama.cpp's failure on one of
    # those reads as a backend problem.
    if [ -f "$file" ]; then
        actual="$(sha256 "$file")"
        if [ "$actual" = "$want" ]; then
            echo "$name  ok ($(du -h "$file" | cut -f1))"
            return 0
        fi
        echo "$name is at $file but is not the pinned model" >&2
        echo "  expected sha256 $want" >&2
        echo "  found           $actual" >&2
        echo "Move it aside and run this again to replace it." >&2
        return 1
    fi

    mkdir -p "$DEST"
    echo "fetching $name ($(( bytes / 1000000 )) MB)"
    curl -fL --progress-bar -o "$file.partial" "$url"

    # A GGUF file begins with the ASCII magic "GGUF", in that order on disk —
    # unlike ggml's, which is a little-endian integer and reads backwards.
    # Checked before the hash so a captive-portal HTML page gets a sentence
    # about what it is rather than a hash mismatch.
    local magic
    magic="$(head -c 4 "$file.partial" | xxd -p | tr -d '\n')"
    if [ "$magic" != "47475546" ]; then
        rm -f "$file.partial"
        echo "that download is not a GGUF model (magic $magic)" >&2
        return 1
    fi

    actual="$(size_of "$file.partial")"
    if [ "$actual" != "$bytes" ]; then
        rm -f "$file.partial"
        echo "$name is $actual bytes, expected $bytes" >&2
        return 1
    fi
    actual="$(sha256 "$file.partial")"
    if [ "$actual" != "$want" ]; then
        rm -f "$file.partial"
        echo "$name does not match its pinned sha256" >&2
        echo "  expected $want" >&2
        echo "  found    $actual" >&2
        return 1
    fi

    mv "$file.partial" "$file"
    echo "$name  verified ($(du -h "$file" | cut -f1))"
}

case "${1:-both}" in
    desktop) fetch "$DESKTOP" ;;
    phone)   fetch "$PHONE" ;;
    both)    fetch "$DESKTOP" && fetch "$PHONE" ;;
    *)       usage ;;
esac
