#!/bin/bash
# Puts the right polish model where a platform's build will find it.
#
# One decision, taken once, applied five ways. Until now polish worked on one
# platform of five: the Mac shipped an 835 MB MLX model, iOS shipped nothing
# and fell back to nothing, and Android, Windows and Linux shipped nothing at
# all. The engine was never the problem — PolishBackendResolver already falls
# through to llama.cpp when no MLX model is registered, and that fall-through
# is pinned by a test. It was always delivery.
#
#   desktop   polish.gguf          1.0 GB   macOS, Windows, Linux
#   phone     polish-0.5b.gguf     469 MB   iOS, Android
#
# Measured on the same sentences before choosing: the 1.5B revises 75% of them
# and the 0.5B 30%. The smaller model is *accepted* more often, because it
# proposes less and the gauntlet has less to reject — which is why acceptance
# rate is the wrong number to choose on. See PolishModelComparison.
#
# The destination filename is always `polish.gguf`, whichever model it is.
# LlamaModelHost.defaultModelURL() looks for exactly that name, so a build that
# stages `polish-0.5b.gguf` under its own name ships a model the engine will
# never find.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIZE="${1:-}"
DESTINATION="${2:-}"

usage() {
    cat >&2 <<'USAGE'
usage: Tools/stage-polish-model.sh <desktop|phone> <destination-directory>

  desktop   stages build/models/polish.gguf      (1.0 GB)
  phone     stages build/models/polish-0.5b.gguf (469 MB)

Both arrive as <destination>/polish.gguf, which is the only name the engine
looks for. Fetch the models first with Tools/fetch-polish-model.sh.
USAGE
    exit 2
}

case "$SIZE" in
    desktop) SOURCE="$ROOT/build/models/polish.gguf" ;;
    phone)   SOURCE="$ROOT/build/models/polish-0.5b.gguf" ;;
    *)       usage ;;
esac
[ -n "$DESTINATION" ] || usage

if [ ! -f "$SOURCE" ]; then
    echo "no model at $SOURCE" >&2
    echo "Fetch it first: Tools/fetch-polish-model.sh" >&2
    exit 1
fi

mkdir -p "$DESTINATION"
TARGET="$DESTINATION/polish.gguf"

# Compared rather than copied every time: these are hundreds of megabytes and
# a build that re-copies one on every run is a build nobody waits for twice.
# See Tools/fetch-polish-model.sh for why GNU's form is asked for first: BSD
# stat rejects -c and fails over cleanly, while GNU stat *accepts* -f with a
# different meaning and prints a block, so -f first silently compares rubbish.
size_of() {
    stat -c %s "$1" 2>/dev/null \
        || stat -f %z "$1" 2>/dev/null \
        || wc -c < "$1" | tr -d ' []'
}

if [ -f "$TARGET" ] && [ "$(size_of "$SOURCE")" = "$(size_of "$TARGET")" ]; then
    echo "polish.gguf already staged ($SIZE)"
    exit 0
fi

cp "$SOURCE" "$TARGET"
echo "staged $(basename "$SOURCE") as polish.gguf ($SIZE) in $DESTINATION"
