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
# Found rather than named: the table moved from VoxScriptaApp to
# VoxScriptaUI when the interface became a library, and a hardcoded path
# failed the app build instead of saying so.
TABLE="$(find "$ROOT/Sources" -name Strings.swift | head -1)"
[ -n "$TABLE" ] || { echo "no Strings.swift under Sources" >&2; exit 1; }
SOURCES=("$TABLE")
while IFS= read -r file; do
    [ "$file" = "${SOURCES[0]}" ] || SOURCES+=("$file")
done < <(grep -rl 'String(localized: "' "$ROOT/Sources" | sort)
STATUS=0

for lproj in "$ROOT"/Resources/Localization/*.lproj; do
    language="$(basename "$lproj" .lproj)"
    strings="$lproj/Localizable.strings"
    [ -f "$strings" ] || continue

    # English is the development language and the keys are English text, so
    # en.lproj is deliberately empty — it exists only so the bundle declares
    # English as a real localization rather than a fallback. Checking it would
    # report every string as missing, which is how this was first noticed.
    if [ "$language" = "en" ]; then
        printf "  %-10s development language, no entries needed\n" "$language"
        continue
    fi

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

# Permission prompts live in InfoPlist.strings, which the system reads and
# Strings.swift cannot reach. Same failure mode — an untranslated prompt looks
# deliberate — so the same comparison, against en.lproj as the reference.
REFERENCE="$ROOT/Resources/Localization/en.lproj/InfoPlist.strings"
if [ -f "$REFERENCE" ]; then
    for lproj in "$ROOT"/Resources/Localization/*.lproj; do
        language="$(basename "$lproj" .lproj)"
        [ "$language" = "en" ] && continue
        translated="$lproj/InfoPlist.strings"
        while read -r key; do
            if [ ! -f "$translated" ] || ! grep -Fq "\"$key\" = " "$translated"; then
                printf "  %-10s missing Info.plist prompt: %s\n" "$language" "$key"
                STATUS=1
            fi
        done < <(grep -o '^"[A-Za-z]*" = ' "$REFERENCE" | tr -d '"' | sed 's/ = //')
    done
fi

exit $STATUS
