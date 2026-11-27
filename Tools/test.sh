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

# The second trap, and a worse one than the metallib because it blames the
# wrong thing. The Command Line Tools toolchain ships no swift-testing, so with
# xcode-select pointing at it every test file fails with `no such module
# 'Testing'` — in targets nobody touched, by the dozen, looking exactly like a
# broken checkout. `swift build` passes throughout, because nothing in the
# library imports Testing. It cost a stash-and-rebuild to establish that the
# code was fine.
#
# Candidates are searched rather than required: hardcoding an Xcode path is one
# of the three faults that kept CI from ever passing, so a missing Xcode gets a
# sentence here instead of a path baked into the script.
if [ -z "${DEVELOPER_DIR:-}" ] && case "$(xcode-select -p 2>/dev/null)" in
       *CommandLineTools*) true ;; *) false ;; esac; then
    for candidate in /Applications/Xcode.app /Applications/Xcode-*.app \
                     "$HOME/Applications/Xcode.app"; do
        if [ -d "$candidate/Contents/Developer" ]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            echo "xcode-select points at the Command Line Tools, which have no"
            echo "swift-testing. Using $candidate for this run."
            break
        fi
    done
    if [ -z "${DEVELOPER_DIR:-}" ]; then
        echo "xcode-select points at the Command Line Tools, which ship no" >&2
        echo "swift-testing — every test file will fail to find module" >&2
        echo "'Testing'. Point at an Xcode and run this again:" >&2
        echo "  sudo xcode-select -s /path/to/Xcode.app/Contents/Developer" >&2
        exit 1
    fi
fi

BIN="$(swift build --package-path "$ROOT" --show-bin-path)"

# Injected copies would break the build that is about to run.
find "$BIN" -name mlx.metallib -delete 2>/dev/null || true

swift build --package-path "$ROOT" --build-tests
"$ROOT/Tools/build-metallib.sh" >/dev/null
swift test --package-path "$ROOT" --skip-build "$@"
