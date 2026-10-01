#!/bin/bash
# Compiles MLX's Metal shaders into mlx.metallib.
#
# This exists because of a documented SwiftPM limitation. mlx-swift's own README
# says it plainly: "SwiftPM (command line) cannot build the Metal shaders so the
# ultimate build has to be done via Xcode." Without the library MLX links
# perfectly and then fails at the first GPU call with "Failed to load the default
# metallib" — a runtime failure from a clean build, which is a miserable thing to
# debug.
#
# Rather than restructure the whole project around an .xcodeproj for this one
# artifact, the eight shader sources are compiled here directly. MLX looks for a
# colocated `mlx.metallib` before anything else, so the result is dropped next to
# each binary that needs it.
#
# Requires the Metal toolchain:  xcodebuild -downloadComponent MetalToolchain
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHADERS="$ROOT/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
OUT="$ROOT/build/mlx.metallib"

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "The Metal toolchain is not installed." >&2
    echo "Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

if [ ! -d "$SHADERS" ]; then
    echo "No MLX shader sources at $SHADERS — run 'swift build' first." >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Compiling MLX Metal shaders"
COUNT=0
for file in "$SHADERS"/*.metal; do
    name="$(basename "$file" .metal)"
    xcrun -sdk macosx metal -c "$file" -I "$SHADERS" -o "$WORK/$name.air"
    COUNT=$((COUNT + 1))
done

mkdir -p "$ROOT/build"
xcrun -sdk macosx metallib "$WORK"/*.air -o "$OUT"
echo "  $COUNT shaders -> $OUT ($(du -h "$OUT" | cut -f1))"

# Place it beside every binary that runs MLX, including the test bundles, so
# `swift test` exercises the real GPU path rather than skipping it.
#
# The bin path moved when Swift 6.4 made the Xcode build system the default, so
# this asks SwiftPM where the binaries are rather than assuming a layout.
#
# Order matters now. The Xcode build system code-signs each .xctest bundle and
# tracks its contents, so a file added afterwards makes the *next* build fail
# to re-sign it. Run this after building and then test without rebuilding:
#
#     swift build --build-tests && ./Tools/build-metallib.sh && swift test --skip-build
#
# A plain `swift build` after this will fail until the injected copies are
# removed, which this script does on each run before copying them back.
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
# Clear previous injections so a rebuild is not tripped by them.
find "$BIN" -name mlx.metallib -delete 2>/dev/null || true
for dir in "$BIN" "$BIN"/*.xctest/Contents/MacOS; do
    [ -d "$dir" ] || continue
    cp "$OUT" "$dir/mlx.metallib"
    echo "  installed into ${dir#"$ROOT"/}"
done
