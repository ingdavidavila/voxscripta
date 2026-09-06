# VoxVerba

Local-first audio transcription for Apple Silicon Macs.

Drop in a recording. VoxVerba analyses it with deterministic signal processing,
transcribes it with an on-device speech model, reassembles one continuous
transcript, and optionally uses a local language model to produce clean and
polished versions — without changing what the speaker actually said.

**The original audio is never modified. Nothing leaves the Mac.**

---

## Status: Phase 8 — export and release

The roadmap is complete. VoxVerba imports a recording, transcribes it on device,
produces three transcripts, and exports any of them in five formats.

```
swift run voxverba-cli export --project /path/to/x.voxverba --to ~/Desktop
./Tools/make-app-bundle.sh && open build/VoxVerba.app
```

| Format | Notes |
|---|---|
| `.txt` | Paragraph structure from measured pauses; optional timestamps |
| `.md` | Markdown syntax in the transcript is escaped, not rendered |
| `.docx` | Office Open XML written directly, no document toolkit |
| `.srt` | Cues split on word timings, two lines maximum |
| `.vtt` | Same, with WebVTT speaker markup |

Plus an opt-in **silence-removed copy of the recording** — rendered from the
original at its own sample rate, with crossfaded joins so the splices do not
click, and a JSON time map so a listener can still locate themselves in the
source (§7).

```
swift run voxverba-cli render-audio --project /path/to/x.voxverba
```

Three variants × five formats = fifteen files, each independently exportable.

259 tests across 46 suites.

### Verified against real parsers, not my own

Subtitle timing is checked by loading the generated `.vtt` with **AVFoundation** —
the same parser QuickTime and Safari use — and asserting the asset duration
matches the last cue's end time. A file it accepts is a file a player accepts.
Testing against a reimplementation of my own writer would only have proven it was
self-consistent.

`.docx` is validated with the system `unzip`, both for archive integrity and for
the presence of every required OOXML part.

### Audio format coverage

Six containers are exercised automatically: **WAV, AIFF, CAF, M4A, FLAC and raw
AAC**, each synthesized at test time.

**MP3 is the exception, and it is skipped rather than passed.** macOS ships no
MP3 encoder — `afconvert` refuses it in every container and `AVAudioFile` has no
format for it — so an MP3 fixture cannot be generated the way the others are.
Drop any MP3 at `Tests/Fixtures/sample.mp3` and the decode test runs against it;
with no file present the suite reports it as *skipped*, so the gap stays visible.

### Intermediates are reclaimed automatically

A job deletes its scratch audio when it finishes — about 1.4 GB per six-hour
recording. `Original/` and `Output/` are never touched, and a reclaimed project
still opens instantly.

That last part needed a fix before cleanup could ship at all: the resume planner
checked derived artifacts *before* checking completion, so a cleaned project
looked unfinished and re-transcribed from scratch. Completion is now decided from
`Output/` and the recorded hashes, neither of which cleanup touches.

The same work surfaced a second inconsistency. Silence and chunk parameters lived
in the manifest, but locale and concurrency did not — so reopening any project
took them from ambient defaults, and if those differed the transcription hash
changed and the whole file was re-transcribed. They now live in the manifest with
everything else.

```
swift run voxverba-cli run audio.wav --project p.voxverba --keep-intermediates
swift run voxverba-cli clean --project p.voxverba
```

### Self-contained: a bundled language model

VoxVerba ships its own model, so POLISHED works on any Apple silicon Mac —
including one where Apple Intelligence is off or unsupported.

| Backend | Source | Used when |
|---|---|---|
| Apple system model (~3B) | macOS | preferred, when available |
| Bundled Qwen2.5-1.5B-Instruct-4bit | inside the app | fallback, or forced in Settings |

The default is **best available**: the system model when it exists, the bundled
one otherwise. Measured on the disfluent corpus the bundled model gives 26.7%
rejection and 20% fallback, against 33%/33% for the system model — close enough
that the guarantee costs little.

```
Tools/fetch-model.sh          # once: downloads the weights into build/Model
Tools/make-app-bundle.sh      # builds a 924 MB app with the model inside
```

Nothing is downloaded at runtime. The app still has **no network entitlement**
and cannot open a socket; the only fetch happens on the build machine.

### Two things this cost

**The dependency count is no longer zero.** `mlx-swift-lm` and swift-transformers
come in, and with them mlx-swift, swift-syntax, swift-numerics,
swift-argument-parser and swift-collections. That was the price of independence
from Apple Intelligence, and it is confined to one target — `VoxVerbaMLX` — so
the validator, the CLEAN pass and the DSP core stay dependency-free.

**SwiftPM cannot build MLX's Metal shaders.** mlx-swift's own README says so:
*"SwiftPM (command line) cannot build the Metal shaders so the ultimate build has
to be done via Xcode."* Without them the app links perfectly and dies at the
first GPU call with *"Failed to load the default metallib"* — a runtime failure
from a clean build. Rather than restructure the project around an `.xcodeproj`
for one artifact, `Tools/build-metallib.sh` compiles the eight shader sources
directly and drops the result where MLX looks first. It needs the Metal
toolchain: `xcodebuild -downloadComponent MetalToolchain`.

### A correction to the architecture

This document previously cited WWDC26's `MLXLanguageModel` bridge — which plugs
MLX into `LanguageModelSession` and keeps `@Generable` guided generation — as the
way to add MLX. **It requires macOS 27**, gated behind
`canImport(FoundationModels, _version: 2)`. On macOS 26 the backend drives
`MLXLLM` directly instead. The cost is small: polish already runs one sentence
per call, so there is no cardinality for a schema to enforce, and all seven
validator checks are unchanged.

### The privacy claim is enforced by the build

```
$ ./Tools/make-app-bundle.sh
  hardened runtime: runtime
  network access:   none (no com.apple.security.network.client entitlement)
```

The bundle script **fails the build** if a network entitlement ever appears. §26
is only meaningful if something checks it, so the check lives in the build rather
than in a checklist.

### What release still needs from you

The app is ad-hoc signed with hardened runtime enabled. `spctl` reports
*rejected*, which is correct — Gatekeeper is asking for notarization, not
reporting a defect. Notarization needs a Developer ID certificate and an Apple
ID, which this repository deliberately does not contain.
[`Docs/RELEASE.md`](Docs/RELEASE.md) has the exact commands.

### The icon

Generated by `Tools/make-icon.swift` rather than committed as a binary, so it
stays reproducible and the concept stays editable: a sound wave on the left
tapering into ruled lines of text on the right (§2).

An earlier attempt tried to morph each wave bar continuously into a text mark,
and the text half read as scattered specks — text is legible because its marks
are *horizontal and joined*, which a field of shortened vertical bars can never
become.

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
