#!/bin/bash
# Builds the engine library, then runs the Dart bindings against it.
#
# The order is the point. These tests exercise a real dlopen of a real
# libVoxScriptaFFI, so a stale library would test yesterday's ABI and pass. The
# build runs first, every time.
#
# Arguments pass through: Tools/test-dart.sh --name "export"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/flutter/voxscripta_engine"

command -v dart >/dev/null 2>&1 || export PATH="$HOME/development/flutter/bin:$PATH"
command -v dart >/dev/null 2>&1 || {
    echo "no dart on PATH — install Flutter, or add its bin directory" >&2
    exit 1
}

swift build --package-path "$ROOT" --product VoxScriptaFFI >/dev/null
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"

case "$(uname -s)" in
    Darwin) LIB="libVoxScriptaFFI.dylib" ;;
    *)      LIB="libVoxScriptaFFI.so" ;;
esac
[ -f "$BIN/$LIB" ] || { echo "no $LIB in $BIN" >&2; exit 1; }

cd "$PACKAGE"
dart pub get >/dev/null
dart analyze
VOXSCRIPTA_LIBRARY="$BIN/$LIB" dart test "$@"
