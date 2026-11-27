#!/bin/bash
# Fails if a library about to be shipped was built without -c release.
#
# `EntitlementStore.debugOverride()` reads VOXSCRIPTA_ENTITLEMENT and forces any
# entitlement state. Its own comment says why that is acceptable: "Compiled out
# of release builds entirely... an environment variable that unlocked a shipping
# build would be the whole paywall, undone in one line by anybody who read this
# file."
#
# The code is right. The packaging was not. The Windows session found that
# stage-windows.sh, stage-linux.sh, the Android build and WINDOWS.md never pass
# `-c release`, so three of five platforms were staging a library with the
# override compiled in — including the one inside a Flutter *release* app, where
# nothing about the app's own configuration says anything about the engine's.
#
# Measured on this Mac before this script was kept:
#   .build/out/Products/Debug/libVoxScriptaFFI.dylib    1 occurrence
#   .build/out/Products/Release/libVoxScriptaFFI.dylib  0 occurrences
#
# So the string's presence is the signal, and it needs no engine, no symbols and
# no platform-specific tooling to read — which is the point, because the check
# has to run on Windows, Linux and macOS staging alike.
#
# usage: Tools/check-release-binary.sh <library> [more libraries...]
set -uo pipefail

# Any debug-only marker worth refusing to ship. Keep each one's reason beside
# it: a list of bare strings rots into a list nobody dares change.
MARKERS=(
    "VOXSCRIPTA_ENTITLEMENT"   # forces any entitlement state, i.e. the paywall
)

[ "$#" -ge 1 ] || { echo "usage: $0 <library> [...]" >&2; exit 2; }

status=0
for library in "$@"; do
    if [ ! -f "$library" ]; then
        echo "  FAIL  $library does not exist" >&2
        status=1
        continue
    fi
    found=""
    for marker in "${MARKERS[@]}"; do
        # `strings` is not everywhere; grep -a over the binary is, and finds the
        # same literal. Checked against both builds above.
        if grep -aqF "$marker" "$library"; then
            found="$found $marker"
        fi
    done
    if [ -n "$found" ]; then
        echo "  FAIL  $(basename "$library") carries debug-only marker(s):$found" >&2
        echo "        It was built without -c release. Rebuild with" >&2
        echo "        'swift build -c release --product VoxScriptaFFI' and stage that." >&2
        status=1
    else
        echo "  ok    $(basename "$library") carries no debug-only marker"
    fi
done
exit "$status"
