# What "the same application" means

Decided 2026-11-01: **same features, native feel on each platform.**

Not pixel parity. The Flutter interface should look and behave like a Windows
application on Windows and an Android application on Android — platform
conventions for navigation, file pickers, menus and controls — while offering
the same capabilities as the SwiftUI app. A user moving between a Mac and a PC
should find everything they had, not the same screenshot.

That makes parity checkable, which is the point of writing it down. The list
below is the contract. A feature added to either interface is added to this
table, or the two have started to drift.

## The guard that already exists

Neither interface contains logic. Every rule — thresholds, transcript
formatting, which model runs — lives in the engine, and both interfaces call
it. `voxscripta_engine` carries no rules for the same reason. This stops the
two from *disagreeing*; it does nothing to stop one from being *missing*
something, which is what the table is for.

## Feature contract

Legend: ✓ in the SwiftUI app · ABI column says whether the C ABI can serve it.

| Feature | SwiftUI | C ABI today |
| --- | --- | --- |
| **Library** | | |
| List projects with duration and date | ✓ | ✓ `vs_library_list` · Flutter ✓ |
| Open a project | ✓ | ✓ — `vs_job_start` opens an existing package |
| Delete a project (recoverable — Trash, or a Deleted folder) | ✓ | ✓ `vs_project_delete` · Flutter ✓ |
| Reveal in the file manager | ✓ | platform-side, not engine |
| **Getting audio in** | | |
| Import an audio file | ✓ | ✓ · Flutter ✓ (platform dialog, or a typed path) |
| Copy the original into the project, or reference it | ✓ | ✗ (always references) |
| Record in the app, with pause and resume | ✓ | ✓ `vs_recording_*` · Flutter ✓ |
| Level meter and elapsed clock while recording | ✓ | ✓ — the meter curve is the engine's · Flutter ✓ |
| Discard a recording | ✓ | ✓ · Flutter ✓ |
| Microphone permission refusal, handled | ✓ | the engine's refusal is shown verbatim · Flutter ✓ |
| **Running a job** | | |
| Progress with the stage and its detail line | ✓ | ✓ · Flutter ✓ |
| Cancel, leaving the project resumable | ✓ | ✓ · Flutter ✓ |
| Resume an interrupted job | ✓ | ✓ — `vs_job_start` with an empty audio path · Flutter ✓ |
| **Reading the result** | | |
| Three variants: verbatim, clean, polished | ✓ | ✓ · Flutter ✓ |
| Copy the transcript to the clipboard | ✓ | ✓ · Flutter ✓ |
| Save as txt, md, docx, srt, vtt | ✓ | ✓ · Flutter renders, cannot yet choose where |
| Include timestamps in an export | ✓ | ✓ via `options_json` |
| Save every variant at once | ✓ | ✓ by repeated calls |
| Polish review: which sentences were accepted or rejected, and why | ✓ | ✓ `vs_project_summary` · Flutter ✓ |
| Explanation when polish did not run | ✓ | ✓ · Flutter ✓ |
| Render silence-removed audio | ✓ (macOS) | ✗ — and AVFoundation-only |
| **Settings** | | |
| Silence: margin dB, minimum duration, lead and trail padding | ✓ | ✓ · Flutter ✓ |
| Chunking: maximum duration | ✓ | ✓ · Flutter ✓ |
| Locale, and detect-language on or off | ✓ | ✓ · Flutter ✓ |
| Available locales on this machine | ✓ | ✓ `vs_capabilities` · Flutter ✓ |
| Concurrency | ✓ | ✓ · Flutter ✓ |
| Clean: fillers, repetitions, low-confidence words | ✓ | ✓ · Flutter ✓ |
| Polish: on or off, and which backend | ✓ | ✓ · Flutter ✓, including which model would really run |
| Default variant to show | ✓ | interface-side |
| Keep intermediate files | ✓ | ✓ · Flutter ✓ |
| **Everywhere** | | |
| A tooltip on every button saying what it does | ✓ | interface-side |
| Dismissible errors carrying the engine's own words | ✓ | ✓ |

## Progress, 2026-11-01

ABI 2 closed the library and the settings. Twelve symbols became seventeen,
and `vs_job_start` and `vs_export` each gained one JSON parameter rather than
a sibling function, because nothing had shipped against version 1 and a legacy
variant kept forever costs more than a break nobody can observe.

Two design notes worth keeping:

**Scalars on the hot path, JSON for anything with shape.** Polling a job is
four integer reads and no allocation. Settings are one string parameter whose
signature never changes as settings are added — the alternatives were a dozen
scalar parameters, or a C struct whose layout three languages and three
platforms would have to agree about forever.

**The engine reports its own defaults**, through `vs_job_options_defaults`.
This matters more than it looks: a settings screen with its own hardcoded
default silence margin is a rule living in an interface, and the moment the
engine changes the two disagree. The Flutter settings screen will render from
what the engine says. For the same reason the library's location moved out of
`AppModel` into `ProjectStore.defaultLibraryDirectory`, so both interfaces ask
rather than each building the path.

ABI 3 added `vs_project_summary`, which the transcript screen needed: which
transcripts exist, their word and segment counts, and what POLISH decided. One
call rather than four, because the screen needs all of it to draw one frame.

Counts and evidence are separated in it, on purpose. A clean run of a long
interview is thousands of accepted sentences, and shipping them all so an
interface could count and discard them would be a megabyte of JSON to render
one number. `flagged` carries only the retries and the fallbacks — the
sentences a reader would actually want to see.

ABI 4 added `vs_capabilities` for the settings screen: the transcription
languages on offer, which of them the text stages understand, which have
enough defence for POLISH to be permitted, and which model POLISH would
actually use. Every line of that is a rule, which is why it is answered by the
engine — a settings screen that worked any of it out for itself would be a
second copy of the engine's judgement, free to disagree with the first. The
same principle runs through the screen: no default is written in Dart, and
setting a value *back* to the engine's default removes the override rather than
pinning today's number forever.

**A gap `vs_capabilities` exposed on the real machine, since fixed.** Both
engines resolved their model by joining `build/models/<name>` onto the
*working directory* — right for a command line run from the project root, and
wrong for every packaged application. A shipped Flutter app would have
reported "no bundled model" with the GGUF sitting beside its executable, and
POLISH would have been quietly absent with no error anywhere.

`ModelSearch` in `VoxScriptaCore` now answers it once for both engines: an
environment override, then beside the executable, then an Apple bundle's
`Resources`, then the development tree found by walking up rather than
assuming a depth. On this machine the symptom went from `bundled model: none`
to `bundled model: llama.cpp, polish.gguf`.

ABI 5 added what the processing screen draws: the audio facts on
`vs_project_summary` — duration, speech regions, the speech spans, how many
waveform buckets exist and how long POLISH will take — and `vs_waveform`
beside it, which returns interleaved Float32 min/max pairs rather than JSON.

Three decisions in that worth keeping:

**Downsampling is the engine's.** `vs_waveform` takes the pixel width the view
will draw at and reduces by taking each span's extremes. Averaging — which is
what an interface reaching for a one-liner would do — flattens every transient,
and a waveform that has lost its transients no longer looks like the audio.

**The speech spans, not only the fraction.** The first version of the screen
had the fraction alone and shaded that share of the width from the left. It
looked like a finding — "the first 71% is speech" — and was not one.

**An empty audio path means resume.** A project package references its own
source, so re-running one needs no audio path. The first version had the
interface pass the project path twice to say this, which worked only because
the audio argument is ignored once a manifest exists: a call that read as a
lie.

ABI 6 added recording, which was the last surface. Two rules moved out of the
Apple-only interface and into the engine on the way: where recordings are
written and what they are called, and the level meter's curve. The curve
especially — two meters moving differently for one microphone would be
describing two different recordings.

**The capture path has now run, once.** `tool/record_check.dart` records three
seconds through the whole stack — Dart, the C ABI, miniaudio, FFmpeg — and the
result is a real file: 1 channel, 44.1 kHz AAC, 2.99 seconds, which macOS's own
`afinfo` reads. That is the first time `PortableRecorder` has executed at all.
It is still only one platform; the device layer on Windows, Linux and Android
remains unexercised, and a microphone cannot be opened in a test suite without
prompting a developer and failing a build server.

Recording also surfaced a bug worth the trip: after `finish()`, `latest.state`
still said `recording`, because cancelling the poll timer left the last reading
in place. A screen trusting it would have shown a finished recording as live.

Importing works, and without a plugin. A file-picker plugin is the right
answer eventually and is the only way to reach Android's document provider —
but it needs CocoaPods on macOS, macOS is the only platform this app can
currently be *run* on, and adding one would have traded a working feature for
an unverifiable one. So the import sheet asks the desktop for its own dialog —
`osascript`, `zenity` or `kdialog`, PowerShell — and always offers a typed
path, which is both the fallback on a machine with no dialog installed and the
only route a test can take.

**Android is deliberately not covered.** There is no shell dialog there, and
that is the point at which the plugin has to arrive.

The whole path has been walked once against a real file:
`tool/import_check.dart` imports `jfk.wav`, runs the pipeline and prints the
result — verbatim, clean and polished transcripts, and the right words.

What is still ✗: copying the original into a project instead of referencing
it, and choosing where an export is saved. Saving needs the same dialog work
as importing and will reuse `FileChooser`.

## What the first version of that table said

**The C ABI covered about a fifth of the application.** It can run a job and
read the result, which was enough to prove the boundary works and is nowhere
near enough to build an interface on. Twelve symbols became the right number
for "does Dart reach Swift at all"; it is the wrong number for this contract.

So the next engineering step is not screens. It is growing the ABI to cover
the rows marked ✗, and the honest order is the order a user meets them:

1. **The library** — list, open, delete. Nothing can be built without it.
2. **Job options** — every setting above, passed into `vs_job_start`. This is
   the largest single gap and the one most likely to shape the ABI's design,
   because a dozen scalars as parameters is not a signature anyone should
   write. A JSON blob in and out is the likely answer, since the engine
   already encodes these types with `Codable`.
3. **Export options** — timestamps, and whatever else `ExportOptions` grows.
4. **Polish review** — the report is already written to disk as JSON; it needs
   reading out.
5. **Recording** — the largest piece, and the one with a real platform
   question underneath it: `PortableRecorder` exists and is tested, but it has
   never run on a machine that is not a Mac.

Two rows will not reach parity by growing the ABI, and should be said plainly
rather than left to be discovered:

- **Silence-removed audio** is AVFoundation-only. Off Apple the time map is
  produced but the audio is not, and `render-audio` throws `notImplemented` by
  name. Closing it means teaching FFmpeg to write the file.
- **Polish is weaker off Apple.** Semantic distance abstains without
  `NLEmbedding`. Spanish has corpus evidence that the lexical checks catch
  every polarity inversion on their own; English does not.
