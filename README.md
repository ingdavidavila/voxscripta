# VoxVerba

Local-first audio transcription for Apple Silicon Macs.

Drop in a recording. VoxVerba analyses it with deterministic signal processing,
transcribes it with an on-device speech model, reassembles one continuous
transcript, and optionally uses a local language model to produce clean and
polished versions — without changing what the speaker actually said.

**The original audio is never modified. Nothing leaves the Mac.**

---

## Status: Phase 7 — the application

VoxVerba is now a Mac app. Drop a recording, watch it process, read the
transcript in three variants, and see what the polish pass was refused.

```
./Tools/make-app-bundle.sh && open build/VoxVerba.app
```

- **Library sidebar** listing recordings with durations; selection opens one, by
  mouse or keyboard.
- **Drop anywhere in the window** — the whole window is the target, because
  aiming at a small well is needless precision.
- **Processing view** with a live waveform showing detected speech regions, a
  phase checklist, and a stop button that leaves the work resumable.
- **Transcript workspace** with Verbatim / Clean / Polished, backed by an
  `NSTextView` so a six-hour transcript scrolls.
- **Review panel** showing what polish changed, what it was refused, and why.
- **Settings** for silence, segmentation, transcription, language and storage.

242 tests across 43 suites.

### The privacy claim, checkable

```
$ codesign -d --entitlements - build/VoxVerba.app | grep network.client
(nothing)
```

The bundle ships with `files.user-selected.read-only` and no network entitlement.
The app cannot open a socket even if a future dependency tried to. That is what
§26 asks for: a structural guarantee rather than a sentence in an About box.

### Keeping the UI responsive

A six-hour job reports progress far faster than anyone can read it — every chunk,
every buffer. Dispatching each report to the main actor would spend the UI's time
laying out the same label instead of drawing, which is what "beachball" actually
means here. A `ProgressRelay` coalesces to 10 Hz, and always lets completion and
cancellation through so the UI can never stick at 97%. Tested directly: a
thousand reports in a burst deliver fewer than twenty.

### Packaging note

The app is an SPM executable wrapped into a bundle by a script, not an
`.xcodeproj`. SwiftPM cannot build a `.app`, and a bare binary has no dock icon,
no activation and no entitlements. Keeping it in the package means one
`swift build` covers everything and the app is checked by the same strict
concurrency settings as the libraries. Moving to a real Xcode project later is
mechanical.

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
