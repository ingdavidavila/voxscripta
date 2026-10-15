#!/bin/bash
# Fails when Strings.swift and the translations have drifted apart.
#
# An untranslated string is invisible at runtime: it falls back to English and
# looks deliberate. The only way to notice is to compare the two files, so that
# comparison belongs in the build rather than in someone's memory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Every file that can produce a translatable key: the interface table plus
# anything calling String(localized:). Discovered rather than listed, so a new
# call site cannot quietly escape the check.
SOURCES=("$ROOT/Sources/VoxScriptaApp/Strings.swift")
while IFS= read -r file; do
    [ "$file" = "${SOURCES[0]}" ] || SOURCES+=("$file")
done < <(grep -rl 'String(localized: "' "$ROOT/Sources" | sort)
STATUS=0

for lproj in "$ROOT"/Resources/Localization/*.lproj; do
    language="$(basename "$lproj" .lproj)"
    strings="$lproj/Localizable.strings"
    [ -f "$strings" ] || continue

    missing=0
    while IFS=$'\t' read -r name english; do
        [ -n "$english" ] || continue
        # Compare on the key, which is the English text itself.
        if ! grep -Fq "\"$english\" = " "$strings"; then
            printf "  %-10s missing: %s\n" "$language" "$name"
            missing=$((missing + 1))
        fi
    done < <(python3 "$ROOT/Tools/extract-strings.py" "${SOURCES[@]}")

    total="$(python3 "$ROOT/Tools/extract-strings.py" "${SOURCES[@]}" | wc -l | tr -d ' ')"
    if [ "$missing" -eq 0 ]; then
        printf "  %-10s %s strings, complete\n" "$language" "$total"
    else
        printf "  %-10s %s of %s missing\n" "$language" "$missing" "$total"
        STATUS=1
    fi
done

exit $STATUS
