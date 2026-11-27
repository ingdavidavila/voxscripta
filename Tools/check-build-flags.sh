#!/bin/bash
# Fails if an engine was compiled for the machine that built it.
#
# ggml defaults GGML_NATIVE to ON, so a build that says nothing about CPU
# features gets the build machine's. That is right for a developer and wrong
# for everything handed to anyone else, and nothing said so until the flags
# were read by hand:
#
#   build/engines/host  -mcpu=native+dotprod+i8mm+nosve+sme   on an Apple M5
#
# `i8mm` and `sme` are absent from the M1, M2 and M3 — SME arrived with the M4 —
# and Package.swift links that archive for macOS. The Windows session found the
# same fault further along on Linux, where ggml compiles with -march=native on
# one developer's Ryzen 7 2700X.
#
# Only the iOS build was right, because cross-compiling forced it to say what it
# targets. This makes every platform say it.
#
# usage: Tools/check-build-flags.sh [build/engines/<abi> ...]
#        with no arguments, every engine directory that exists
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$#" -gt 0 ]; then
    TARGETS=("$@")
else
    TARGETS=()
    for d in build/engines/*/; do
        [ -d "$d" ] && TARGETS+=("${d%/}")
    done
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "  ok    no engine has been built here, so none can be mis-targeted"
    exit 0
fi

status=0
for target in "${TARGETS[@]}"; do
    name="$(basename "$target")"
    if [ ! -d "$target" ]; then
        echo "  FAIL  $target does not exist" >&2
        status=1
        continue
    fi

    # Both spellings, because ARM takes -mcpu and x86 takes -march, and a check
    # that knew only one would pass the other half of the problem.
    found="$(grep -rhoE '\-m(cpu|arch)=native[a-z0-9.+-]*' "$target" 2>/dev/null \
             | sort -u | tr '\n' ' ')"
    if [ -n "$found" ]; then
        echo "  FAIL  $name was built for this machine: $found" >&2
        echo "        Set GGML_NATIVE=OFF and name the baseline explicitly." >&2
        echo "        Apple silicon: -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod," >&2
        echo "        which is what an M1 has and is verified to build here." >&2
        status=1
    else
        # Report what it *is* targeting, so a reader can judge the baseline
        # rather than only learn that it is not 'native'.
        aimed="$(grep -rhoE '\-m(cpu|arch)=[a-z0-9.+-]+' "$target" 2>/dev/null \
                 | sort | uniq -c | sort -rn | head -1 | sed 's/^ *//')"
        echo "  ok    $name targets ${aimed:-an unrecorded baseline}"
    fi
done
exit "$status"
