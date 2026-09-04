# VoxVerba

Local-first audio transcription for Apple Silicon Macs.

Drop in a recording. VoxVerba analyses it with deterministic signal processing,
transcribes it with an on-device speech model, reassembles one continuous
transcript, and optionally uses a local language model to produce clean and
polished versions — without changing what the speaker actually said.

**The original audio is never modified. Nothing leaves the Mac.**

---

## Status: Phase 3 — persistence and recovery

A job now survives being killed. Every stage commits its output atomically and
records a hash of its inputs, so an interrupted run resumes at the boundary it
reached rather than starting over.

Implemented:

- **`AtomicFile`** — write to a temporary file, `F_FULLFSYNC`, rename, then fsync
  the directory. A reader never sees a half-written artifact.
- **`JobStore`** — SQLite in WAL mode with `synchronous = FULL`. Raw `SQLite3`
  rather than an ORM, so the project stays dependency-free and builds offline.
- **`ProjectStore`** — package creation and opening, with the import policy
  settled as a **setting**: reference the user's file by default, or copy it in.
- **`ResumePlanner`** — content-addressed invalidation. Changing a silence
  threshold invalidates the silence map and everything after it, and leaves the
  expensive canonical decode alone.
- **`JobRunner`** — the state machine, persisting after each stage.
- **`voxverba-cli run --project <dir>`** — creates or resumes.

178 tests across 34 suites.

### The gate

Killed with `SIGKILL` at every stage, then resumed, the transcript is
byte-identical to an uninterrupted run:

```
swift run voxverba-cli run speech.wav --project /tmp/p --crash-at chunking
swift run voxverba-cli run --project /tmp/p --out transcript.txt
```

Crash points cover decode, analyze, silence, chunking, mid-transcription and
merge. Also verified: a completed project is not recomputed, a silence-parameter
change reuses the decode, a changed source forces a full rebuild, and a cancelled
job resumes without redoing finished chunks.

### What is reproducible, precisely

| Scope | Reproducible? |
|---|---|
| Decode, analysis, silence, chunk planning | **Yes** — always byte-identical |
| Transcription at concurrency 1 | **Yes** |
| Transcription at concurrency > 1 | **No** |
| Paragraph structure | **Yes** — from the silence map, not the engine |

The third row is not about the concurrency *setting*: two clean runs at
concurrency 4 with identical settings differ, because request interleaving inside
the shared speech service is not reproducible. On an eight-minute file the
difference was one tokenization, "river bank" versus "riverbank".

That found a real bug. Paragraph breaks were computed from gaps between
consecutive engine segments, so document structure inherited that
nondeterminism — a resumed job could produce the same words in different
paragraphs. Breaks now come from the `SilenceMap`, which is deterministic DSP
output. Concurrency is also part of the transcription stage's input hash, so
resuming at a different setting re-transcribes rather than mixing results.

### Earlier phases

Phase 1 built the deterministic audio core — streaming decode, vDSP frame
analysis, the five-stage silence detector, and cost-minimising chunk planning,
all validated against a synthetic corpus with exact ground truth. See
[`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md) for the noise-floor design note.

## Trying it

```
swift run corpus-gen /tmp/vv-corpus
swift run voxverba-cli analyze /tmp/vv-corpus/continuous_speech.wav --chunk-max 60
```

## Requirements

- macOS 26 or later, Apple Silicon
- Xcode 26 / Swift 6.3
- No network connection, at build time or at run time

## Build

```
swift build
swift test
```

Open `Package.swift` directly in Xcode for a full IDE session. There is no
`.xcodeproj` yet — the SwiftUI app target arrives in Phase 7, when there is an
app to put in it.

```
swift run voxverba-cli help
```

## Architecture

The full technical architecture — technology comparisons, the silence-detection
cascade, the anti-hallucination validation design, memory strategy, and the
phased roadmap — is in [`Docs/ARCHITECTURE.md`](Docs/ARCHITECTURE.md).

The load-bearing idea, in one paragraph: everything upstream of the speech model
is reproducible. Given the same audio and the same parameters, the decoder, the
silence detector, and the chunk planner produce byte-identical output every time.
That property is what makes resume correct, makes tests meaningful, and makes it
possible to state confidently that no model influenced the audio segmentation.

## Module graph

```
VoxVerbaCore          identifiers, timing, transcript model, state machines
  ├── VoxVerbaDSP             decode · analyse · detect silence · plan chunks
  │     └── VoxVerbaTranscription   engines · scheduler · merger
  ├── VoxVerbaLanguage        clean (rules) · polish (LLM) · validation
  ├── VoxVerbaProject         package format · job store · resume
  ├── VoxVerbaExport          TXT · Markdown · DOCX · SRT · VTT
  └── VoxVerbaBench           signposts · footprint · benchmark reports
```

Dependencies point one way only, and SPM enforces it: a module cannot import a
target it does not declare.

## Privacy

VoxVerba ships without the `com.apple.security.network.client` entitlement, so
the sandbox prevents it from opening a socket even if a dependency tried. CI
additionally fails the build if any source file references a networking API.

There is no telemetry, no analytics, and no transmitting crash reporter.

## Licence

Not yet chosen.
