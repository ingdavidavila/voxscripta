/* The Vox Scripta engine's C ABI.
 *
 * Hand-written to match Sources/VoxScriptaFFI/VoxScriptaFFI.swift, which is
 * where the reasoning behind each decision lives. This file is what Dart's
 * ffigen reads to generate bindings; it is not compiled into the library, so if
 * the two ever disagree, the Swift is right and this is a bug.
 *
 * The library is loaded at runtime: libVoxScriptaFFI.dylib on macOS,
 * libVoxScriptaFFI.so on Linux and Android, VoxScriptaFFI.dll on Windows.
 *
 * Ownership, in one rule: every pointer returned by a function ending in _copy,
 * and the buffer from vs_export, was allocated by the library and must be
 * released by vs_string_free or vs_bytes_free. Never free() them. On Windows a
 * DLL and its host can hold separate C runtime heaps, and freeing across them
 * corrupts both.
 *
 * Threading: nothing here blocks except vs_job_start's setup, which is a few
 * filesystem calls. The job itself runs on the library's own executor and is
 * observed by polling. vs_last_error_copy is per OS thread, so two Dart
 * isolates never read each other's failures.
 */

#ifndef VOXSCRIPTA_H
#define VOXSCRIPTA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ─── Job states, as vs_job_state returns them ─────────────────────────── */

#define VS_STATE_UNKNOWN_HANDLE  (-1)  /* released, or never issued */
#define VS_STATE_IMPORTED          0
#define VS_STATE_ANALYZING         1
#define VS_STATE_SILENCE           2
#define VS_STATE_CHUNKING          3
#define VS_STATE_TRANSCRIBING      4
#define VS_STATE_MERGING           5
#define VS_STATE_CLEANING          6
#define VS_STATE_POLISHING         7
#define VS_STATE_COMPLETE          8
#define VS_STATE_FAILED            9
#define VS_STATE_CANCELLED        10
#define VS_STATE_STARTING        100  /* accepted; no stage has reported yet */

/* ─── Version ──────────────────────────────────────────────────────────── */

/* Bumped when a symbol changes meaning or disappears. Check it once at load
 * and refuse to run against an ABI you were not built for. */
int32_t vs_abi_version(void);

/* ─── Errors ───────────────────────────────────────────────────────────── */

/* The last failure on the calling thread, or NULL if the last call succeeded.
 * Caller releases with vs_string_free. */
char *vs_last_error_copy(void);

/* ─── Jobs ─────────────────────────────────────────────────────────────── */

/* Creates or opens the project at project_path for the audio at audio_path,
 * then runs the pipeline. Returns a handle, or a negative number on refusal
 * with the reason in vs_last_error_copy:
 *
 *   -1  an argument was NULL
 *   -2  an argument was the empty string
 *
 * Returns immediately. Anything that can only be discovered by doing the work
 * — missing audio, an unreadable container — arrives later as VS_STATE_FAILED
 * with vs_job_error_copy, not as a negative return here.
 *
 * The original audio is referenced, never copied and never modified. */
int64_t vs_job_start(const char *audio_path, const char *project_path);

/* One of the VS_STATE_* codes. */
int32_t vs_job_state(int64_t handle);

/* Completion in 0...1. Zero for an unknown handle — check vs_job_state. */
double vs_job_fraction(int64_t handle);

/* The progress line to show. Caller releases with vs_string_free. */
char *vs_job_detail_copy(int64_t handle);

/* Why a job failed, or NULL while it has not. Caller releases. */
char *vs_job_error_copy(int64_t handle);

/* Asks a job to stop at the next stage boundary, leaving the project
 * resumable. This is not a rollback. 0 if delivered, -1 for an unknown
 * handle. */
int32_t vs_job_cancel(int64_t handle);

/* Forgets a handle, cancelling the job first if it is still running. */
void vs_job_release(int64_t handle);

/* ─── Export ───────────────────────────────────────────────────────────── */

/* Renders a finished transcript.
 *
 *   variant  "verbatim" | "clean" | "polished"
 *   format   "txt" | "md" | "docx" | "srt" | "vtt"
 *
 * On success returns 0 and writes a buffer to *out_bytes with its length in
 * *out_length; release it with vs_bytes_free. Returns a negative code on
 * failure, with the reason in vs_last_error_copy:
 *
 *   -1  a required argument was NULL
 *   -2  no such variant
 *   -3  no such format
 *   -4  the transcript could not be read or rendered
 *
 * Bytes rather than a string because docx is a ZIP. */
int32_t vs_export(const char *project_path,
                  const char *variant,
                  const char *format,
                  uint8_t **out_bytes,
                  int64_t *out_length);

/* ─── Releasing what the library returned ──────────────────────────────── */

void vs_bytes_free(uint8_t *bytes);
void vs_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif /* VOXSCRIPTA_H */
