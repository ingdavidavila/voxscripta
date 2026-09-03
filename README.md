# VoxVerba

Local-first audio transcription for Apple Silicon Macs.

Drop in a recording. VoxVerba analyses it with deterministic signal processing,
transcribes it with an on-device speech model, reassembles one continuous
transcript, and optionally uses a local language model to produce clean and
polished versions — without changing what the speaker actually said.

**The original audio is never modified. Nothing leaves the Mac.**

---

## Status: Phase 2 — transcription and measurement

The pipeline runs end to end: audio in, one merged transcript out, entirely
on-device. The language passes (clean, polished) are Phase 4 onward.

Implemented:

- **`AppleSpeechEngine`** — `SpeechAnalyzer` / `SpeechTranscriber` on macOS 26,
  fed directly from the memory-mapped canonical file with word-level timings.
- **`ChunkScheduler`** — bounded concurrency, exponential-backoff retries, and a
  commit callback that is the seam for Phase 3's durable writes. A permanently
  failed chunk leaves a gap marker; the job continues.
- **`TranscriptMerger`** — orders by sequence and de-duplicates hard-cut overlaps
  by matching word text *and* timestamps, flagging any splice it cannot resolve.
- **`SpokenNumbers` / `WordErrorRate`** — number-aware comparison, so a correct
  transcript that writes "500" for "five hundred" scores zero errors.
- **`corpus-gen --speech`** — synthesized speech with an exact reference text.
- **`voxverba-cli transcribe | bench | wer`**

153 tests across 31 suites.

### Measured on this machine (Apple M5, macOS 26.5)

| Metric | Value |
|---|---|
| Throughput | **113× real time** (8 min file, concurrency 4) |
| Word error rate | **4.4 – 5.6%** on synthesized speech |
| Peak footprint | **14 MB** |
| Chunked vs single-chunk | **0.00% WER** — chunking is invisible |

Reproduce it:

```
swift run corpus-gen /tmp/vv-bench --speech 8
swift run voxverba-cli bench /tmp/vv-bench/speech.wav --chunk-max 45 --concurrency 1,2,4,8
swift run voxverba-cli transcribe /tmp/vv-bench/speech.wav --out /tmp/hyp.txt
swift run voxverba-cli wer /tmp/vv-bench/speech.reference.txt /tmp/hyp.txt
```

The WER figure is against synthesized speech — clean, no overlap, no background
noise. It is a regression guard, not a claim about real recordings.

### A prediction the benchmark overturned

The architecture argued for a default concurrency of **1**, reasoning that Neural
Engine inference is a serialized resource that extra in-flight work would only
contend for. Measurement disagreed: transcription took 4.74 s at concurrency 1,
2.72 s at 2, and 2.14 s at 4, flattening at 8 and regressing at 12.

The cause is the property that made the Apple engine attractive for memory — it
runs in a **system process**, which pipelines requests across clients. Peak
footprint rose only 11 MB → 20 MB across the entire sweep. The default is now 4.

One caveat worth knowing: output is byte-identical across runs at a fixed
concurrency, but *not* across different values. Concurrency is recorded in
`Provenance` so resume can reuse it.

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
