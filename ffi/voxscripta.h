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
 * and refuse to run against an ABI you were not built for.
 *
 * 2 added the library, job options and export options.
 * 3 added vs_project_summary.
 * 4 added vs_capabilities.
 * 5 added the audio facts to vs_project_summary, and vs_waveform.
 * 6 added recording.
 * 7 added the sign-up password rules. */
int32_t vs_abi_version(void);

/* ─── Structured data ──────────────────────────────────────────────────────
 *
 * Scalars on the hot path, JSON for anything with shape. Polling a job is four
 * integer reads and no allocation; settings are one string parameter that
 * never changes signature as settings are added.
 *
 * Pass NULL or "" for any *_json input to mean "the engine's defaults". Read
 * the defaults with vs_job_options_defaults / vs_export_options_defaults
 * rather than hardcoding them — a default in an interface is a rule the other
 * interface cannot see.
 */

/* ─── Errors ───────────────────────────────────────────────────────────── */

/* The last failure on the calling thread, or NULL if the last call succeeded.
 * Caller releases with vs_string_free. */
char *vs_last_error_copy(void);

/* ─── Jobs ─────────────────────────────────────────────────────────────── */

/* Creates or opens the project at project_path for the audio at audio_path,
 * then runs the pipeline.
 *
 * audio_path may be "" to resume a project that already exists, since a
 * package references its own source. It is required only to create one. Returns a handle, or a negative number on refusal
 * with the reason in vs_last_error_copy:
 *
 *   -1  an argument was NULL
 *   -2  an argument was the empty string
 *   -3  options_json would not decode, or named a backend that does not exist
 *
 * Returns immediately. Anything that can only be discovered by doing the work
 * — missing audio, an unreadable container — arrives later as VS_STATE_FAILED
 * with vs_job_error_copy, not as a negative return here.
 *
 * The original audio is referenced, never copied and never modified. */
int64_t vs_job_start(const char *audio_path,
                     const char *project_path,
                     const char *options_json);

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
                  const char *options_json,
                  uint8_t **out_bytes,
                  int64_t *out_length);

/* ─── Library ──────────────────────────────────────────────────────────────── */

/* Where projects live when nobody says otherwise. Caller releases. */
char *vs_library_default_directory(void);

/* The projects in a directory, as a JSON array, newest first. NULL or "" means
 * the default library. An empty library returns "[]" and is not an error.
 * Caller releases.
 *
 *   [{"id": "...", "path": "...", "displayName": "...",
 *     "durationSeconds": 0.0, "state": "complete", "modifiedAt": 0.0}]
 *
 * `state` reads "complete" for every project with a readable manifest — the
 * real state lives in each project's job store and opening one per row would
 * cost a database open per entry. The SwiftUI library pane says the same
 * slightly-too-optimistic thing, on purpose: both interfaces agreeing beats
 * each guessing differently. */
char *vs_library_list(const char *directory);

/* Deletes a project, recoverably: to the Trash on a Mac, otherwise to a
 * Deleted folder beside the library. The original audio survives either way.
 *
 * 0 on success, writing {"movedTo": "<path>"} (or null) to *out_json, which the
 * caller releases with vs_string_free. Negative on failure, leaving *out_json
 * untouched, with the reason in vs_last_error_copy. */
int32_t vs_project_delete(const char *project_path, char **out_json);

/* ─── A finished project ───────────────────────────────────────────────────── */

/* What a project contains, as JSON. Caller releases.
 *
 *   {"variants": [{"variant": "verbatim", "words": 0, "segments": 0}, ...],
 *    "polish": {"ran": true, "skipReason": null,
 *               "accepted": 0, "acceptedAfterRetry": 0, "keptClean": 0,
 *               "flagged": [{"disposition": "fellBackToClean",
 *                            "original": "...", "revised": "...",
 *                            "reasons": ["..."]}]}}
 *
 * `variants` lists only the transcripts that exist, so a project still being
 * processed reports fewer than three and an unfinished one reports none. That
 * is not an error.
 *
 * `flagged` carries only the sentences worth looking at — anything accepted on
 * a retry, and anything where the CLEAN text had to stand. A clean run of a
 * long interview is thousands of plain acceptances, and shipping them so a
 * caller can count and discard them would be a megabyte of JSON to render one
 * number. The counts are separate; this is the evidence.
 *
 * `skipReason` is set, and `ran` false, when POLISH declined — so a missing
 * polished transcript is never unexplained.
 *
 * `audio` carries what is known about the recording, filled in as the stages
 * that produce it run:
 *
 *   "audio": {"durationSeconds": 0.0, "speechRegions": null,
 *             "speechFraction": null, "waveformBuckets": null,
 *             "speechSpans": [[0.0, 1.2], ...],
 *             "polishEstimateSeconds": 0.0}
 *
 * speechSpans carries where speech was detected, not only how much of it there
 * is. An interface given the fraction alone can only shade that share of the
 * width from one end, which reads as a finding and is not one.
 *
 * The nulls are "not yet", not "none" — the processing screen shows what it
 * has. polishEstimateSeconds applies the measured 1.4 seconds of polishing per
 * second of audio; the rate is a measurement and therefore a rule, which is
 * why it is applied here and not in an interface.
 *
 * NULL on failure, with the reason in vs_last_error_copy. */
char *vs_project_summary(const char *project_path);

/* The waveform, as interleaved little-endian Float32 min/max pairs.
 *
 * `buckets` is how many pairs are wanted — pass the pixel width of the view
 * that will draw it, or 0 for every bucket the analysis produced. On success
 * returns 0 and writes 2 * buckets * 4 bytes to *out_bytes, released with
 * vs_bytes_free.
 *
 * Bytes rather than JSON: a few thousand buckets as decimal text is twenty
 * times the size, for a drawing redrawn on every resize. Downsampling happens
 * in the engine because taking each span's extremes is the only reduction that
 * keeps a waveform looking like the audio; averaging flattens every transient.
 *
 * Returns -5 before the analysis stage has run, which is a state to show and
 * not an error. */
int32_t vs_waveform(const char *project_path,
                    int32_t buckets,
                    uint8_t **out_bytes,
                    int64_t *out_length);

/* ─── What this machine can do ─────────────────────────────────────────────── */

/* The settings screen's facts, as JSON. Caller releases.
 *
 *   {"locales": [{"identifier": "en-US", "displayName": "English (US)",
 *                 "hasTextSupport": true, "polishValidated": true}, ...],
 *    "polish": {"systemModelAvailable": true, "bundledModel": "...",
 *               "effective": "Apple on-device model",
 *               "unavailableReason": null}}
 *
 * hasTextSupport is whether CLEAN and POLISH understand the language at all.
 * Transcription works either way; the text stages do not, because applying one
 * language's filler list to another deletes real words.
 *
 * polishValidated is whether POLISH is permitted in it. A language whose
 * polarity lexicon is empty has no defence against a reversed meaning, so the
 * gauntlet refuses it rather than running unguarded.
 *
 * `effective` is what would actually run, in the same words the provenance
 * records; `unavailableReason` is set instead when nothing would.
 *
 * Every line of this is a rule, which is why it is answered here rather than
 * worked out by each interface. Blocks briefly: asking the recogniser which
 * locales it supports is a call into a system service.
 *
 * NULL on failure, with the reason in vs_last_error_copy. */
char *vs_capabilities(void);

/* ─── Defaults ─────────────────────────────────────────────────────────────── */

/* The engine's own settings, as JSON in the same shape the *_json inputs take.
 * Caller releases. */
char *vs_job_options_defaults(void);
char *vs_export_options_defaults(void);

/* ─── Recording ────────────────────────────────────────────────────────────
 *
 * Same shape as a job — a handle, then polling — and for the same reason: a
 * level meter calling back into the host sixty times a second from a capture
 * thread is the crash the job surface was designed to avoid. Four scalar reads
 * at 20 Hz cost nothing.
 *
 * NOTE: the capture device layer underneath this has never run on a machine
 * that is not a Mac. The writer is tested on both paths; opening a microphone
 * cannot be tested without a microphone.
 */

/* Recording states, as vs_recording_state returns them. */
#define VS_RECORDING_UNKNOWN_HANDLE (-1)
#define VS_RECORDING_IDLE             0
#define VS_RECORDING_RECORDING        1
#define VS_RECORDING_PAUSED           2

/* The folder recordings are written to, and a new non-colliding path inside
 * it. Both read from the engine so the two interfaces agree about where a
 * recording lands. Caller releases. */
char *vs_recording_directory(void);
char *vs_recording_new_path(void);

/* Opens the microphone and starts writing to destination_path, or to a newly
 * generated path when it is NULL or "".
 *
 * Returns a handle, or negative with the reason in vs_last_error_copy. The file
 * is readable while it is being written — the writer emits fragments, so a
 * crash costs the last fragment rather than the recording. */
int64_t vs_recording_start(const char *destination_path);

int32_t vs_recording_state(int64_t handle);

/* Seconds actually written, excluding anything paused. */
double vs_recording_elapsed(int64_t handle);

/* The meter, already mapped onto 0...1. Normalized in the engine because the
 * mapping is a measured curve, and two meters moving differently for one
 * microphone would describe two different recordings. */
double vs_recording_level(int64_t handle);

/* Why capture or writing failed part-way through, or NULL. A report rather
 * than a state: a recording can fail after it started and what was written so
 * far is still good. Caller releases. */
char *vs_recording_failure_copy(int64_t handle);

int32_t vs_recording_pause(int64_t handle);
int32_t vs_recording_resume(int64_t handle);

/* Stops, finalizes and forgets the handle, writing {"path": "...",
 * "seconds": 0.0} to *out_json for the caller to release. */
int32_t vs_recording_finish(int64_t handle, char **out_json);

/* Stops and deletes what was written. The one call here that destroys audio,
 * and only because the user asked: §5 protects original files, and a recording
 * just thrown away is not one yet. */
int32_t vs_recording_discard(int64_t handle);

/* ─── Sign-up rules ────────────────────────────────────────────────────────
 *
 * Read rather than reimplemented: a password that passed on a phone and
 * failed on a desktop would be a bug, and one definition prevents it.
 *
 * NOTE: these check composition, which is a weak measure of strength. What
 * protects an account is rate limiting, breach-list rejection and a second
 * factor, none of which lives on this side of the boundary. Whatever service
 * holds the credentials should enforce its own rules too.
 */

/* Every rule, each marked met or not, as a JSON array. Caller releases.
 *
 *   [{"id": "length", "demand": "At least 8 characters", "satisfied": false},
 *    {"id": "uppercase", ...}, {"id": "number", ...}, {"id": "special", ...}]
 *
 * All four are returned every time, not only the failures, so a form can show
 * the whole checklist filling in as someone types. */
char *vs_password_rules(const char *password);

/* Whether a string could be an email address. 1 yes, 0 no. Permissive by
 * design — only a delivered message proves an address works. */
int32_t vs_email_looks_valid(const char *address);

/* ─── The paywall ──────────────────────────────────────────────────────────
 *
 * Three days from first launch, then a subscription. The gate is enforced
 * inside the library: vs_job_start and vs_recording_start both return -3 once
 * it is up, so an interface cannot forget to ask. Nothing else is ever
 * refused for payment — reading a transcript, copying it, exporting any
 * format, reviewing polish, deleting a project and every setting all keep
 * working, because that is the user's own work on the user's own disk.
 *
 * Verification is the caller's job and cannot be otherwise: the proof of a
 * subscription is a StoreKit 2 transaction signed by Apple, a Play Billing
 * purchase, or whatever a direct sale issues. Check it on that side and
 * record the result here. */

/* What this machine may do, as JSON. Caller releases.
 *
 *   {"state": "trialing", "allowsNewWork": true,
 *    "shouldOfferSubscription": true, "trialDays": 3,
 *    "trialDaysRemaining": 2, "trialSecondsRemaining": 123456.0,
 *    "period": null, "through": null, "lapsedSince": null, "refusal": null}
 *
 * "state" is one of "trialing", "trialExpired", "subscribed",
 * "subscriptionLapsed". Key off that, not off "refusal", which is English
 * prose for callers that cannot localize. Every key is always present.
 *
 * Reading this moves the trial's high-water mark forward, which is what stops
 * a clock set backwards from returning days already spent. */
char *vs_entitlement_state(void);

/* Records a subscription the caller has already verified. 0, or -1 with
 * vs_last_error_copy set.
 *
 *   {"productID": "voxscripta.monthly", "period": "monthly",
 *    "expires": 1764600000.0, "graceUntil": null}
 *
 * "period" is "monthly" or "yearly". "expires" and "graceUntil" are seconds
 * since 1970; omit them when the store did not say, which is treated as
 * open-ended — do not pass 0 to mean "unknown". */
int32_t vs_entitlement_record_subscription(const char *subscription_json);

/* Forgets the subscription: a refund, or a restore that found nothing. The
 * trial clock is untouched, so a spent trial is not handed back. Returns 0. */
int32_t vs_entitlement_clear_subscription(void);

/* ─── Releasing what the library returned ──────────────────────────────── */

void vs_bytes_free(uint8_t *bytes);
void vs_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif /* VOXSCRIPTA_H */
