#!/bin/bash
# Downloads the language model that ships inside VoxVerba.app.
#
# Run once. The weights are not in the repository — a gigabyte of binary has no
# place in git — so this fetches them into build/Model, and make-app-bundle.sh
# copies them into the app.
#
# This is the only network operation anywhere in the project, it happens on the
# build machine, and the shipped app has no network entitlement at all.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/build/Model}"

# Qwen2.5-1.5B-Instruct at 4-bit: about 870 MB. Chosen as the smallest model that
# still rewrites a sentence without mangling it, since it has to fit inside an app
# people will move around. A larger model can be used instead — point the app at
# any mlx-community directory in Settings.
REPO="${VOXVERBA_MODEL_REPO:-mlx-community/Qwen2.5-1.5B-Instruct-4bit}"
BASE="https://huggingface.co/$REPO/resolve/main"

REQUIRED=(config.json tokenizer.json tokenizer_config.json)
OPTIONAL=(special_tokens_map.json generation_config.json chat_template.jinja)
WEIGHTS=(model.safetensors)

mkdir -p "$DEST"
echo "Fetching $REPO into $DEST"

for f in "${REQUIRED[@]}" "${WEIGHTS[@]}"; do
    if [ -s "$DEST/$f" ]; then echo "  have $f"; continue; fi
    echo "  $f"
    curl -sL -f -o "$DEST/$f" "$BASE/$f" || { echo "FAILED: $f" >&2; exit 1; }
done

for f in "${OPTIONAL[@]}"; do
    [ -s "$DEST/$f" ] && continue
    curl -sL -f -o "$DEST/$f" "$BASE/$f" 2>/dev/null || rm -f "$DEST/$f"
done

echo
echo "done — $(du -sh "$DEST" | cut -f1) in $DEST"
echo "run Tools/make-app-bundle.sh to build an app with the model inside"
