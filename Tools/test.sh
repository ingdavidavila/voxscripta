#!/bin/bash
# Builds, places the MLX metallib, and runs the tests — in that order.
#
# Exists because the order is a trap. The Xcode build system signs each .xctest
# bundle and tracks its contents, so the metallib that MLX needs beside the
# binary makes the *next* build fail to re-sign. Doing it by hand means
# remembering to clear the injected copies first; this does it every time.
#
# Arguments are passed through: Tools/test.sh --filter Spanish
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"

# Injected copies would break the build that is about to run.
find "$BIN" -name mlx.metallib -delete 2>/dev/null || true

swift build --package-path "$ROOT" --build-tests
"$ROOT/Tools/build-metallib.sh" >/dev/null
swift test --package-path "$ROOT" --skip-build "$@"
