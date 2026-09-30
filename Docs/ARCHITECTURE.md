# Vox Scripta — Technical Architecture

Revision 1. Target: Apple M5, 24 GB, macOS 26.5, Xcode 26.6, Swift 6.3.

An illustrated version of this document, with the decision matrices and the
silence-detector diagram, is published as an Artifact. This file is the
authoritative in-repo copy.

---

## 1. Philosophy

Vox Scripta decodes an audio file exactly once into a canonical PCM scratch file,
measures it with deterministic DSP, transcribes it with an on-device ASR engine,
and reconstructs one continuous transcript on the recording's **original**
timeline. A local language model is invited in only at the last step, in small
windows, behind a validator that rejects any output which added, dropped, or
altered a fact.

**The load-bearing idea.** Everything upstream of the language model is
reproducible. Given the same audio and the same parameters, the decoder, the
silence detector, and the chunk planner produce byte-identical output every
time. That property is what makes resume correct, makes tests meaningful, and
makes it possible to state confidently that the LLM did not influence
segmentation. The probabilistic part of the system is deliberately small, late,
and fenced.

---

## 2. Three deviations from the original specification

Each of these is a decision that gets expensive to reverse, so they are recorded
here rather than discovered later.

### 2.1 Silence is skipped, not spliced

Splicing audio at silence boundaries and re-encoding creates discontinuities
that Whisper-family models reliably hallucinate into, and it destroys the
mapping back to real timestamps.

Instead the detector produces a `SilenceMap`, and the scheduler simply never
sends silent regions to the model. The full DSP detector is still built — it
drives segmentation instead of destructive editing. "Render silence-removed
audio" remains available as an explicit export.

### 2.2 Chunks are ranges, not files

Writing `chunk_0001.wav` … `chunk_0400.wav` for a six-hour file means ~1.4 GB of
redundant I/O and 400 file handles to leak. A chunk is instead a
`SampleRange` — an (offset, length) view into one memory-mapped
`canonical.f32`. Same metadata, same resume semantics, none of the cost.

### 2.3 CLEAN uses no LLM

Modern on-device ASR already emits punctuated, capitalized text. Everything the
CLEAN variant requires — punctuation, paragraphs, capitalization, artifact
repair, disfluency removal — is achievable with deterministic rules over a
structured transcript plus pause timings.

CLEAN therefore carries a hallucination risk of exactly zero, which matters
because it is the variant most users will actually read. The LLM is confined to
POLISHED.

---

## 3. Technology stack

| Layer | Choice | Rationale |
|---|---|---|
| App & UI | Swift 6 + SwiftUI, targeted AppKit | Native throughout; AppKit only for the multi-hour transcript viewer |
| Decode / resample | AVFoundation + AVAudioConverter | Every required format, streaming, hardware-assisted, no FFmpeg |
| DSP | Accelerate (vDSP / vForce) | Hand-tuned SIMD from pure Swift, no FFI boundary |
| Speech-to-text | `SpeechAnalyzer` / `SpeechTranscriber`; WhisperKit alternate | See §5 |
| LLM runtime | Foundation Models API; Apple 3B and MLX backends | See §6 |
| NLP utilities | NaturalLanguage framework | On-device tokenization, lemmatization, NER, embeddings |
| Job persistence | SQLite in WAL mode (GRDB) | Atomic, crash-safe, queryable chunk state |
| Project storage | Filesystem package directory | User-inspectable, Time Machine friendly |
| DOCX export | Hand-written OOXML via ZIPFoundation | A .docx is a zip of XML; ~300 lines |
| Instrumentation | OSSignposter + `task_vm_info` | Real measurements, not estimates |

**Dependency budget.** Two third-party packages in V1: GRDB and ZIPFoundation,
both MIT. WhisperKit is a third if the alternate engine ships in V1. Everything
else is Apple frameworks. Phase 0 has **zero** dependencies and builds offline.

---

## 4. Audio pipeline

### 4.1 Canonicalization

The source is opened read-only via `AVAudioFile`, read in 10-second buffers,
converted to 16 kHz mono 32-bit float, and appended to `canonical.f32`. This
happens once; every later stage memory-maps that file. Six hours occupies
1.38 GB on disk and, mapped read-only, effectively nothing in dirty footprint.

### 4.2 Frame analysis

One sequential pass computes, per 25 ms Hann-windowed frame at a 10 ms hop:
short-time RMS in dBFS, zero-crossing rate, and spectral flatness (Wiener
entropy) from a 512-point real FFT. Feature frames cost ~360 bytes per second of
audio, so a six-hour file's full feature set is ~8 MB and stays resident —
making threshold re-tuning in the UI instant with no audio re-read.

### 4.3 Silence detection — five stages, in order

Fixed amplitude thresholds fail on exactly the material that matters. The
cascade:

1. **Noise floor estimation.** Minimum-statistics tracker over a sliding 3 s
   window, taking a low percentile of frame energies, smoothed asymmetrically
   (rises slowly, falls quickly) so sustained speech does not drag it upward.

2. **Adaptive dual thresholds.** `exit = max(floor + margin, absoluteFloor)`,
   `enter = exit + hysteresis`. Both float with the noise floor; the absolute
   clamp stops a near-silent studio recording from chasing dither.

3. **Fricative protection.** A frame below `exit` is held as speech if it is
   adjacent to confirmed speech *and* shows high ZCR together with high spectral
   flatness. `/s/`, `/f/`, `/ʃ/`, `/θ/` carry little energy but are spectrally
   unmistakable; a pure RMS gate truncates them and the transcript loses plurals
   and possessives.

4. **Duration gating.** Speech runs shorter than `minSpeechDuration` are demoted
   to silence *first*, then silence runs shorter than `minSilenceDuration` are
   promoted to speech. Reversing the order merges noise into speech.

5. **Asymmetric padding.** Outward only — `padLead` before, `padTrail` after,
   with trailing larger because word-final decay outlasts word-initial onset.

**Preserving pause semantics.** The `SilenceMap` records every gap's duration.
The merger consults it: a gap past `paragraphPauseThreshold` becomes a paragraph
break, past `sectionPauseThreshold` a section break. So

> "Hello…" [5 s silence] "…my name is David."

emerges as two paragraphs, because the pause was measured and carried forward
rather than discarded.

### 4.4 Chunk planning

For each boundary the planner searches `[minDuration, maxDuration]` for the best
silence gap, scoring on gap length (saturating), proximity to target duration,
and depth below the noise floor. The cut goes at the gap's midpoint,
`boundaryKind = .silence`.

If nothing clears the minimum score — continuous speech, a lecture without
pauses, music underneath — it forces a cut at `maxDuration`, marks `.hardCut`,
and extends the next chunk backward by `overlapDuration`. Only hard cuts carry
overlap.

**Why 2–5 minutes and not 30 seconds.** A common mistake is sizing chunks to a
model's input window. Whisper's encoder takes 30 s, but every serious runtime
handles long-form internally, and `SpeechAnalyzer` is explicitly designed for
continuous input. Feeding either engine 30-second slices *hurts* accuracy by
stripping context. Vox Scripta's chunks exist for checkpointing, memory bounding,
and progress reporting — none of which relate to model windows.

### 4.5 Merging

Chunks sort by `sequence`. Soft boundaries concatenate plainly. Hard boundaries
take ~40 words each side, normalize them, and find the longest common
subsequence whose word timestamps agree within tolerance; the splice point is
the end of that match. On failure the merger splits at the nominal boundary and
records `SegmentWarning.mergeAmbiguity` rather than hiding the uncertainty.

---

## 5. Speech-to-text

**Default: `SpeechTranscriber` (SpeechAnalyzer). Alternate: WhisperKit.**

The popular answer is Whisper, and on this OS and chip it is no longer the
strongest for English.

The case for Apple's engine: independent benchmarks report it ahead of
Whisper-small on LibriSpeech (≈2.1% vs 3.7% clean, 4.6% vs 8.0% other) at
roughly 3× the speed. Its models are OS-managed through `AssetInventory` — no
bundle weight, no download UI for the default path. It runs in a system process,
so model memory never enters this app's footprint and an engine crash cannot
take down the app. It emits `audioTimeRange` word timings, which the merger and
the polish validator both need. And it was designed for long-form rather than
adapted to it.

WhisperKit stays as the alternate for reasons that will not go away: Apple
covers ~30 locales against Whisper's 100+, and an OS-versioned model cannot give
the cross-machine reproducibility the benchmark suite needs.

**Rejected.** whisper.cpp — not on quality but on fit: no ANE use, and WhisperKit
runs the same models faster through CoreML with no C++ bridging. MLX Whisper —
Python-centric and slower than the CoreML path.

**V2.** Parakeet TDT v3 via FluidAudio brings speaker diarization. Adding it
means writing one `TranscriptionEngine` conformance.

> All figures above are third-party published benchmarks, not measurements taken
> on this machine. Phase 2 exists to measure them. The engine choice is a runtime
> setting precisely so measurement can overturn this recommendation without an
> architectural change.

---

## 6. Local LLM

**Foundation Models framework as the API, with two interchangeable backends.**

WWDC26 opened the framework to third-party backends through a `LanguageModel`
protocol and shipped `MLXLanguageModel`, which loads any mlx-community model
into the same Swift API. Model choice stops being an architectural commitment.

- **Standard** — `SystemLanguageModel.default`, Apple's ~3B on-device model.
  Zero download, zero bundle weight, ~4096-token context.
- **High quality** — `MLXLanguageModel` with a user-selected model. Qwen3-8B or
  Llama-3.1-8B at 4-bit is ~5 GB, comfortable on 24 GB.

The 4096-token context is not a constraint: the anti-hallucination design
independently forces windows of 3–8 sentences. The correct safety design and the
small-model constraint point the same direction.

**Rejected.** Ollama — a shipping Mac app cannot require a separately installed
background daemon, and a sandboxed app talking to localhost HTTP undermines the
privacy claim. llama.cpp — adds a C++ target and GGUF plumbing for a runtime
with materially worse time-to-first-token on M5, which matters acutely when
polishing is thousands of short prompts where prefill dominates.

---

## 7. Anti-hallucination architecture

Designed on the assumption that the model **will** produce bad output regularly
and the system's job is to catch it.

### Containment

- **Window scope.** 3–8 sentences per call, one sentence of read-only context
  each side. The model never sees enough to summarize.
- **Determinism.** Temperature 0, fixed seed where exposed, a frozen system
  prompt versioned alongside the code.
- **Structural constraint.** A `@Generable` output type requiring one revised
  sentence per input sentence, each carrying its source index. Cardinality
  violations fail at the framework level before any check runs.

### The gauntlet — seven deterministic checks

| # | Check | Mechanism | Catches |
|---|---|---|---|
| 1 | Cardinality | Guided-generation schema | Merged, dropped, invented sentences |
| 2 | Numeric conservation | Normalize numerals and number-words to canonical value+unit; **strict set equality** | "500 units" → "approximately 1,000 units" |
| 3 | Named-entity conservation | `NLTagger` `.nameType`; strict set equality | Renamed, dropped, invented people/companies |
| 4 | Polarity | Negation-marker count delta | "we did not approve" → "we approved" |
| 5 | Modality | Hedge lexicon delta | Qualified statement → flat assertion |
| 6 | Semantic floor | `NLEmbedding` cosine ≥ 0.85 | Paraphrase drift |
| 7 | Extent bounds | Length ratio ∈ [0.5, 1.5]; content-word Jaccard ≥ 0.5 | Summarization, wholesale rewriting |

Checks 2 and 3 use **strict equality rather than similarity** precisely because
"approximately 1,000" is *plausible* — a fuzzy check would let it through.

Any failure triggers one retry with a stricter prompt; a second failure falls
back to CLEAN text for that window and flags the segment. Polished output is
never silently accepted. Every polished sentence stores its source segment IDs
and a `ValidationReport`, so the UI can render a diff.

---

## 8. State machine and recovery

**Job states.** `imported → analyzing → silenceProcessing → chunking →
transcribing → merging → cleaning → polishing → complete`, with `failed` and
`cancelled` reachable from any working state.

**Chunk states.** `pending → inFlight → completed`, plus `retryScheduled`,
`failedPermanent`, `skipped`.

A chunk retries up to 3 times with backoff. On permanent failure the job does
**not** abort: the chunk is marked `skipped`, a gap marker is inserted, and
processing continues. A 200-chunk lecture with one corrupt region yields 199
good chunks and a visible marker, not a failed job.

### Two invariants make recovery work

1. **Atomic commit.** Write to a temp file in the same directory, `fsync`,
   `rename`. POSIX rename within a filesystem is atomic, so a reader never sees
   a partial file. SQLite runs in WAL mode so power loss rolls back cleanly.

2. **Content-addressed invalidation.** Each stage hashes its inputs — audio
   content hash, parameters, engine identity, model identity, prompt version. On
   resume only what actually changed is invalidated. Adjusting the silence
   threshold invalidates the silence map, chunk plan, and transcription — but
   not the expensive canonical decode.

A cancelled job is indistinguishable from a crashed one to the resume planner,
so the cancel path is exercised by every crash-recovery test.

---

## 9. Memory strategy

Target ceiling: ~2 GB resident with the Apple ASR engine, ~7 GB with an 8B MLX
model, on a machine where 12–16 GB should be assumed available.

Rules enforced in code:

- **The source file is never fully read.** No code path loads a buffer spanning
  the whole file; the decoder's buffer size is a compile-time constant.
- **One canonical copy.** Decoding happens once; later stages map that file.
- **Mapped, not read.** Read-only mappings are clean pages the kernel can evict,
  which is why 1.38 GB of audio costs almost nothing in footprint.
- **One model at a time.** The ASR engine is released before the LLM loads.
- **Bounded concurrency.** A semaphore caps in-flight chunks; results are
  written and released immediately, never accumulated.
- **Pressure response.** A `DispatchSource` memory-pressure handler drops
  concurrency on warn and pauses scheduling on critical.

**On concurrency — prediction corrected by measurement.**

This document originally argued that concurrency 1 was right, on the reasoning
that Neural Engine inference is a serialized hardware resource which extra
in-flight work would only contend for. **That was wrong**, and the benchmark
harness built in Phase 2 is what showed it.

Measured on an M5, 8 minutes of speech, 45-second chunks:

| Concurrency | Transcribe | Peak footprint | vs. best |
|---:|---:|---:|---:|
| 1 | 4.74 s | 11 MB | 138% slower |
| 2 | 2.72 s | 12 MB | 37% slower |
| **4** | **2.14 s** | **14 MB** | **7% slower** |
| 8 | 1.99 s | 20 MB | best |
| 12 | 2.07 s | 25 MB | regresses |

The reason is the same property that made the Apple engine attractive for memory
in the first place: it runs in a **system process**, which pipelines requests
across clients. Model memory never enters this app, so concurrency costs almost
nothing in footprint — 11 MB to 20 MB across the whole sweep.

The default is **4**: it captures all but 7% of the available speedup at
two-thirds the memory of 8, and 12 is already regressing.

**A determinism caveat that matters for resume.** Engine output is byte-identical
across runs *at a fixed concurrency*, but not identical *across* concurrency
values — the shared service segments slightly differently under load. In an
8-minute file the difference was a single tokenization ("river bank" versus
"riverbank"). Concurrency is therefore recorded in `Provenance`, and Phase 3's
resume must reuse the value a job started with.

---

## 10. Testing strategy

**Synthetic corpus with exact ground truth.** `corpus-gen` renders known text
via `AVSpeechSynthesizer` offline, then composes test cases: silences of exact
durations at exact offsets, noise at measured SNRs, gain ramps, every sample
rate, mono and stereo, every container format. The transcript is known
character-for-character and every silence boundary to the millisecond — so WER
and detector accuracy are fully automatable, with no human transcription and no
licensing question about the audio.

**Mutation testing the validator.** The gauntlet's job is catching bad LLM
output, so it is tested against bad output — generated deliberately rather than
waited for. Known-good polished text is corrupted one class at a time: change a
number, swap a name, delete a negation, drop a hedge, merge two sentences,
summarize, add a plausible clause. **A corruption that passes the gauntlet is a
test failure.** This turns "does it hallucinate?" into a CI assertion.

**Crash recovery.** `SIGKILL` at every state, driven through `voxscripta-cli`,
then resume; the final transcript must be byte-identical to an uninterrupted run.

**Memory.** `task_vm_info.phys_footprint` sampled in-test with hard assertions
against per-stage budgets.

### Measured results (Phase 2, Apple M5, macOS 26.5)

Every figure below comes from `voxscripta-cli bench` and is reproducible with the
commands in the README. Nothing here is estimated.

| Metric | Value | Conditions |
|---|---|---|
| Throughput | **113× real time** | 8 min speech, concurrency 4, whole pipeline |
| Word error rate | **4.4 – 5.6%** | synthesized speech, 273–1080 reference words |
| Peak footprint | **14 MB** | 8 min file, concurrency 4 |
| Chunked vs single-chunk agreement | **0.00% WER** | identical text either way |

Two caveats stated plainly. The WER figure is against *synthesized* speech, which
is clean and free of overlap, accents and background noise — it is a regression
guard, not a claim about real recordings, and it is not comparable to a published
LibriSpeech number. And the throughput figure comes from an 8-minute file; a
six-hour recording has not yet been measured end to end.

---

## 11. Security and privacy

- **No network entitlement.** The app ships without
  `com.apple.security.network.client`; the sandbox enforces it at the kernel
  level. Checkable with `codesign -d --entitlements`. CI additionally fails the
  build if any source file references a networking API.
- **Read-only source access.** Security-scoped bookmark, read-only intent, no
  write path anywhere in the codebase.
- **Zero telemetry.** No analytics, no transmitting crash reporter, no
  first-run phone-home. Anything derived from user content is logged
  `privacy: .private`.
- **No credentials.** Nothing to store, so no Keychain use.

---

## 12. Roadmap

| Phase | Scope | Gate |
|---|---|---|
| **P0** ✅ | Skeleton — packages, boundaries, strict concurrency, CI, CLI stub | `swift test` green; zero warnings |
| **P1** ✅ | Deterministic audio core + synthetic corpus | Boundary error within tolerance across all formats; planner property tests pass |
| **P2** ✅ | Transcription + benchmark harness | One merged transcript; WER recorded; concurrency measured |
| **P3** | Persistence and recovery | `SIGKILL` at every state → resume → byte-identical transcript |
| **P4** | CLEAN (deterministic) | Stable output; no meaning-affecting edits on review |
| **P5** | Validation gauntlet | Every mutation-suite corruption class caught |
| **P6** | POLISHED | Measured rejection rate; every rejection retried or cleanly flagged |
| **P7** | Application | Full workflow; UI responsive through a six-hour job |
| **P8** | Export and release | SRT/VTT frame-accurate; entitlements confirm no network |

The gauntlet (P5) is built **before** the model that needs it (P6). The fence
goes up before the gate opens.

**Deferred to V2:** speaker diarization, live microphone transcription, in-app
recording, transcript editing, search, batch processing, watch folders,
translation, iCloud. None require revisiting V1's architecture — which is the
test of whether the boundaries were drawn correctly.
