# VoxVerba

Local-first audio transcription for Apple Silicon Macs.

Drop in a recording. VoxVerba analyses it with deterministic signal processing,
transcribes it with an on-device speech model, reassembles one continuous
transcript, and optionally uses a local language model to produce clean and
polished versions — without changing what the speaker actually said.

**The original audio is never modified. Nothing leaves the Mac.**

---

## Status: Phase 1 — deterministic audio core

The audio pipeline is implemented and measured against a synthetic corpus whose
ground truth is exact by construction. No speech or language model is involved
yet; that is Phase 2.

Implemented:

- **`CanonicalDecoder`** — streaming decode of WAV, AIFF, CAF and M4A at any
  sample rate, mono or stereo, into 16 kHz mono float PCM. Buffers are sized from
  a constant, so peak memory does not scale with recording length.
- **`FrameAnalyzer`** — RMS dBFS, zero-crossing rate and spectral flatness per
  25 ms window at a 10 ms hop, via vDSP over a memory-mapped file.
- **`NoiseFloorTracker`** — minimum-statistics estimator with asymmetric
  smoothing and a flatness-gated cap (see below).
- **`SilenceDetector`** — the full five-stage cascade.
- **`ChunkPlanner`** — cost-minimising boundary search with hard-cut fallback.
- **`corpus-gen`** — deterministic ground-truth corpus, nine cases.
- **`voxverba-cli analyze`** — the whole chain, human-readable or JSON.

119 tests across 26 suites.

### One design note worth recording

Minimum-statistics noise tracking has a failure mode that is easy to miss: it
assumes silence exists somewhere in the window. A lecture with no pauses makes
the estimator track *speech*, which pushes the thresholds above the speech and
detects nothing at all.

The fix caps the local estimate a fixed distance below the file's loud level —
but that cap must not apply to a recording of pure room tone, or it drags the
floor down and reports hiss as speech. Level alone cannot tell those two cases
apart, since both are homogeneous. **Spectral flatness can**: voiced speech is a
harmonic stack and measures near zero, room tone is broadband and measures high.
So the cap is gated on the flatness of the loudest frames.

Both cases are locked in by tests (`continuous_speech` and `room_tone_only`).

## Trying it

```
swift run corpus-gen /tmp/vv-corpus
swift run voxverba-cli analyze /tmp/vv-corpus/long_pause.wav
swift run voxverba-cli analyze /tmp/vv-corpus/continuous_speech.wav --chunk-max 60
```

The second command shows the planner falling back to hard cuts with overlap when
the audio offers no usable pause.

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
