#!/bin/bash
# Holds ffi/voxscripta.h to the library it describes.
#
# The header is hand-written: Swift's @_cdecl emits symbols, not declarations,
# so nothing generates it and nothing stops it drifting. A drifted header is the
# worst kind of bug to find later — Dart's ffigen would read it, produce
# bindings that compile, and call with the wrong signature at runtime.
#
# So this compiles a C client against the header, links it against the real
# library, and runs it. A missing symbol fails at link; a changed signature
# fails at compile. It is not a test of behaviour — VoxScriptaFFITests does that
# — it is a test that the two files still describe the same thing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build --package-path "$ROOT" --product VoxScriptaFFI >/dev/null

case "$(uname -s)" in
    Darwin) LIB="libVoxScriptaFFI.dylib" ;;
    *)      LIB="libVoxScriptaFFI.so" ;;
esac
[ -f "$BIN/$LIB" ] || { echo "no $LIB in $BIN" >&2; exit 1; }

# Every symbol in the header is referenced, so the link proves all of them
# exist rather than only the ones a demo happens to call.
cat > "$WORK/abi.c" <<'C'
#include "voxscripta.h"
int main(void) {
    void *used[] = {
        (void *)vs_abi_version,  (void *)vs_last_error_copy,
        (void *)vs_job_start,    (void *)vs_job_state,
        (void *)vs_job_fraction, (void *)vs_job_detail_copy,
        (void *)vs_job_error_copy, (void *)vs_job_cancel,
        (void *)vs_job_release,  (void *)vs_export,
        (void *)vs_bytes_free,   (void *)vs_string_free,
        (void *)vs_library_default_directory,
        (void *)vs_library_list, (void *)vs_project_delete,
        (void *)vs_job_options_defaults,
        (void *)vs_export_options_defaults,
        (void *)vs_project_summary,
        (void *)vs_capabilities, (void *)vs_waveform,
        (void *)vs_recording_directory, (void *)vs_recording_new_path,
        (void *)vs_recording_start,     (void *)vs_recording_state,
        (void *)vs_recording_elapsed,   (void *)vs_recording_level,
        (void *)vs_recording_failure_copy,
        (void *)vs_recording_pause,     (void *)vs_recording_resume,
        (void *)vs_recording_finish,    (void *)vs_recording_discard,
        (void *)vs_password_rules,      (void *)vs_email_looks_valid,
        (void *)vs_entitlement_state,
        (void *)vs_entitlement_record_subscription,
        (void *)vs_entitlement_clear_subscription,
    };
    (void)used;
    /* One real call, so the library is actually loaded and initialized. */
    return vs_abi_version() == 8 ? 0 : 1;
}
C

cc -I "$ROOT/ffi" -o "$WORK/abi" "$WORK/abi.c" \
   -L "$BIN" -lVoxScriptaFFI -Wl,-rpath,"$BIN"

"$WORK/abi"
echo "ABI ok — all 36 symbols resolve and vs_abi_version() is 8"
