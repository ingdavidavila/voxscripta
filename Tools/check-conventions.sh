#!/bin/bash
# Checks the few conventions a script can actually check.
#
# Docs/CONVENTIONS.md has sixteen rules. Most are judgements a program cannot
# make: whether a default fails closed, whether a fixture resembles real input,
# whether a stopgap was deleted. Pretending otherwise would be rule 13's third
# face — a check judged by eye, dressed up as automation.
#
# What a script *can* check is whether the other checks are wired to anything.
# That is the failure that cost the most here: check-localization.sh existed,
# worked, and was invoked by nothing, so it failed locally for three weeks while
# the macOS release bundle could not be built and nobody knew. This is the gate
# that watches the gates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
status=0

fail() { echo "  FAIL  $1" >&2; status=1; }
pass() { printf "  ok    %s\n" "$1"; }

# ── Rule 12, the unwired face ────────────────────────────────────────────────
# Every gate in Tools/ that exists to be run by CI must be named by CI. A new
# check-*.sh that nothing invokes is the exact shape of the three-week failure.
WORKFLOW=".github/workflows/ci.yml"
if [ ! -f "$WORKFLOW" ]; then
    fail "no $WORKFLOW — the gates have nowhere to run"
else
    for gate in check-abi.sh check-localization.sh check-conventions.sh; do
        if grep -q "$gate" "$WORKFLOW"; then
            pass "$gate is wired into CI"
        else
            fail "Tools/$gate exists and CI never runs it (CONVENTIONS rule 13)"
        fi
    done
fi

# ── Rule 12, the pipe face ───────────────────────────────────────────────────
# A gate whose output goes through a pipe reports the pipe's exit status. Both
# sessions got this wrong, once into a git push with findings on screen. The
# repository's own scripts have never done it; this keeps it that way.
piped="$(grep -rnE '(check-[a-z-]+\.sh|test\.sh|flutter analyze|swift build)[^|&]*\|[[:space:]]*(tail|head|grep)' \
          Tools/ "$WORKFLOW" 2>/dev/null | grep -v 'check-conventions.sh' || true)"
if [ -n "$piped" ]; then
    echo "$piped" >&2
    fail "a gate is judged through a pipe (CONVENTIONS rule 13)"
else
    pass "no gate is judged through a pipe"
fi

# ── Rule 1, as far as a script can reach ─────────────────────────────────────
# The conventions only bind anyone if they are loaded. CLAUDE.md is what every
# session reads without being asked; if it stops naming the conventions, the
# rules are a document nobody opens — which is rule 1 applied to rule 1.
if [ ! -f CLAUDE.md ]; then
    fail "no CLAUDE.md — nothing loads the conventions automatically"
elif ! grep -q "CONVENTIONS.md" CLAUDE.md; then
    fail "CLAUDE.md does not point at Docs/CONVENTIONS.md (CONVENTIONS rule 1)"
else
    pass "CLAUDE.md points at the conventions"
fi

# ── Rule 14 ──────────────────────────────────────────────────────────────────
# The ABI symbol count lives in check-abi.sh, where it is compared. A second
# copy in prose rotted twice: bindings.dart said "thirty-three symbols" when it
# was 38, and it is 41 now.
counted="$(grep -oE 'all [0-9]+ symbols' Tools/check-abi.sh | grep -oE '[0-9]+' | head -1 || true)"
if [ -z "$counted" ]; then
    fail "check-abi.sh no longer states a symbol count for this check to compare"
else
    stale="$(grep -rniE '\b(thirty|forty|fifty)[a-z-]*[[:space:]]+symbols|\b[0-9]+ symbols' \
              ffi/ flutter/voxscripta_engine/lib/ Sources/VoxScriptaFFI/ 2>/dev/null \
              | grep -viE "$counted symbols" || true)"
    if [ -n "$stale" ]; then
        echo "$stale" >&2
        fail "a symbol count is written in prose and disagrees with check-abi.sh ($counted)"
    else
        pass "no stale symbol count in prose"
    fi
fi

# Every "rule N" this repository cites has to land on a rule that exists.
#
# This script cited rule 12 twice for clauses belonging to rule 13, because the
# rule it meant had been renumbered under it. Rule 15 says numbers in prose rot
# and belong where they are compared — so here is where they are compared. The
# document's rule numbers are now stable names rather than positions, which is
# what makes this check possible at all.
cited="$(grep -rhoE 'rule [0-9]+' Tools/ Sources/ Docs/CONVENTIONS.md 2>/dev/null \
          | grep -oE '[0-9]+' | sort -un || true)"
missing=""
for n in $cited; do
    grep -qE "^### $n\. " Docs/CONVENTIONS.md || missing="$missing $n"
done
if [ -n "$missing" ]; then
    fail "cited CONVENTIONS rules that do not exist:$missing"
else
    pass "every cited rule number exists"
fi

# The ABI version is pinned in four places and nothing proved they agree.
#
# Bumping it to 13 left the Swift test asserting 12 and the check-abi.sh C
# assertion asserting 12, while its own success message had already been
# changed to say 13 — prose and assertion disagreeing inside one file. The test
# caught one of those. Nothing would have caught the combination that matters
# most: an engine at 13 with the Dart package still at 12, which ships an app
# that refuses to load its own engine.
engine_abi="$(grep -oE 'private let abiVersion: Int32 = [0-9]+' \
               Sources/VoxScriptaFFI/VoxScriptaFFI.swift | grep -oE '[0-9]+$' || true)"
dart_abi="$(grep -oE 'supportedAbiVersion = [0-9]+' \
             flutter/voxscripta_engine/lib/src/engine.dart | grep -oE '[0-9]+$' || true)"
c_abi="$(grep -oE 'vs_abi_version\(\) == [0-9]+' Tools/check-abi.sh \
          | grep -oE '[0-9]+$' || true)"
test_abi="$(grep -oE 'vs_abi_version\(\) == [0-9]+' \
             Tests/VoxScriptaFFITests/FFISurfaceTests.swift | grep -oE '[0-9]+$' || true)"
# The fifth pin is a file rather than a line of source, so that a build system
# with no Swift parser can read it. The Android side needs that: after a bump,
# staged jniLibs are silently the old ABI and the app only says so at launch —
# a release bundle built happily around one. Checked here rather than written
# here, because a gate with a side effect dirties the tree it is run in.
file_abi="$(tr -d '[:space:]' < Tools/abi-version.txt 2>/dev/null || true)"
if [ -z "$engine_abi" ]; then
    fail "cannot find the engine's abiVersion for this check to compare"
elif [ "$dart_abi" = "$engine_abi" ] && [ "$c_abi" = "$engine_abi" ] \
     && [ "$test_abi" = "$engine_abi" ] && [ "$file_abi" = "$engine_abi" ]; then
    pass "all five ABI pins agree ($engine_abi)"
else
    echo "  engine $engine_abi / dart $dart_abi / check-abi $c_abi" >&2
    echo "  test $test_abi / Tools/abi-version.txt $file_abi" >&2
    fail "the ABI version is pinned in five places and they disagree"
fi

if [ "$status" -eq 0 ]; then
    echo "Conventions ok — the mechanizable ones. The rest are in Docs/CONVENTIONS.md"
    echo "and are a reader's job, not this script's."
fi
exit "$status"
