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
| List projects with duration and date | ✓ | ✓ `vs_library_list` |
| Open a project | ✓ | ✓ — `vs_job_start` opens an existing package |
| Delete a project (recoverable — Trash, or a Deleted folder) | ✓ | ✓ `vs_project_delete` |
| Reveal in the file manager | ✓ | platform-side, not engine |
| **Getting audio in** | | |
| Import an audio file | ✓ | partly — `vs_job_start` takes a path |
| Copy the original into the project, or reference it | ✓ | ✗ (always references) |
| Record in the app, with pause and resume | ✓ | ✗ |
| Level meter and elapsed clock while recording | ✓ | ✗ |
| Discard a recording | ✓ | ✗ |
| Microphone permission refusal, handled | ✓ | platform-side |
| **Running a job** | | |
| Progress with the stage and its detail line | ✓ | ✓ |
| Cancel, leaving the project resumable | ✓ | ✓ |
| Resume an interrupted job | ✓ | ✓ (implicit on restart) |
| **Reading the result** | | |
| Three variants: verbatim, clean, polished | ✓ | ✓ |
| Copy the transcript to the clipboard | ✓ | ✓ via export |
| Save as txt, md, docx, srt, vtt | ✓ | ✓ |
| Include timestamps in an export | ✓ | ✓ via `options_json` |
| Save every variant at once | ✓ | ✓ by repeated calls |
| Polish review: which sentences were accepted or rejected, and why | ✓ | ✗ |
| Explanation when polish did not run | ✓ | ✗ |
| Render silence-removed audio | ✓ (macOS) | ✗ — and AVFoundation-only |
| **Settings** | | |
| Silence: margin dB, minimum duration, lead and trail padding | ✓ | ✓ |
| Chunking: maximum duration | ✓ | ✓ |
| Locale, and detect-language on or off | ✓ | ✓ |
| Available locales on this machine | ✓ | ✗ |
| Concurrency | ✓ | ✓ |
| Clean: fillers, repetitions, low-confidence words | ✓ | ✓ |
| Polish: on or off, and which backend | ✓ | ✓ |
| Default variant to show | ✓ | interface-side |
| Keep intermediate files | ✓ | ✓ |
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

What is still ✗: recording, polish review, available locales, and copying the
original into a project instead of referencing it.

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
