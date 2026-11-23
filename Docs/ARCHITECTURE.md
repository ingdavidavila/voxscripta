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
| Peak footprint | **14 MB** | 8 min file, concurrency 4 |
| Chunked vs single-chunk agreement | **0.00% WER** | identical text either way |

Two caveats stated plainly. The throughput figure comes from an 8-minute file; a
six-hour recording has not yet been measured end to end. And every accuracy
figure here is against *synthesized* speech, which is clean and free of overlap
and real background noise — these are regression guards, not claims about real
recordings, and none of them is comparable to a published LibriSpeech number.

### Accuracy (Phase 3, 10-core / 24 GB Mac, macOS 26.6.2, Apple engine)

The single word-error-rate figure that used to sit in the table above — 4.4 to
5.6% — has been withdrawn, because the benchmark corpus showed it was not
measuring what it appeared to.

The passages it ran on were built to exercise what the polish validator
protects: names, numbers, dates, negations, hedges. Names are the hardest case
in any recogniser, and on a seventy-word reference a handful of them *is* the
whole rate. `northwind` was lost in all eighteen rows of the first conditioned
run; `sara`, `chen`, `quizá` and `unidades` in all nine rows of their
language's. Four fixed errors out of seventy words is 5.6%. The acoustic
conditions were moving one or two other words, which rounds back to the same
number — which is why that first table was flat across every condition.

Measured again on name-free prose of ordinary vocabulary (149–157 reference
words, so one error is about 0.67 points and a difference under ~1.3 points is a
single word and not signal):

| Condition | English | Spanish |
|---|---|---|
| clean | **1.3%** | **2.7%** |
| quiet, −18 dB | 1.3% | 2.0% |
| hum, 12 dB SNR | 1.3% | 2.7% |
| music bed, 10 dB SNR | 1.3% | 2.0% |
| machinery noise, 6 dB SNR | 1.9% | **4.7%** |
| broadband hiss, 12 dB SNR | **3.8%** | **5.4%** |
| 3 s pauses | **5.1%** | 2.0% |
| abrupt ending | 1.3% | 2.7% |
| decaying final word, 1.2 s fade | 1.3% | 2.7% |

Reproduce with `VOXSCRIPTA_CORPUS=1 swift test --filter CorpusMeasurementRun`.
Four results carry consequences:

- **The engine hears roughly four times better than the old figure suggested,
  and names roughly four times worse.** Both halves were invisible while the two
  were averaged into one number. Name accuracy is now its own pair of cases
  (`en_entities`, `es_entities`) rather than contaminating the acoustic figures.
- **Signal-to-noise ratio does not predict damage.** Broadband hiss roughly
  triples English error; 60 Hz hum at the *same* ratio costs nothing measurable
  in either language. Anything that judges whether a recording is usable has to
  look at the spectrum, not the level.
- **Spanish degrades about 2.5× harder than English under machinery noise**
  (2.7 → 4.7 against 1.3 → 1.9), though the two are within 1.4 points on clean
  audio. The Spanish complaint is a noise-robustness problem, not a flat
  accuracy deficit.
- **Three-second pauses are the worst English condition** at 5.1%, four times
  clean, and the only condition producing deletions *and* insertions together.
  Spanish is untouched by the same pauses. Insertions at pause boundaries from a
  streaming recogniser point at premature finalization — and pauses are what the
  chunk planner cuts on.

Both tail conditions scoring exactly as clean is the evidence that the
final-word truncation fix holds.

Character error rate is reported beside word error rate throughout, because the
gap between them is diagnostic: a high word rate with a low character rate is an
orthography problem, the reverse is a hearing problem. On clean English the two
are 1.3% and 0.8%; under hiss they move together to 3.8% and 2.0%.

Still unmeasured, and listed so the gaps are not mistaken for passes:
`ggml-medium` has not been compared against `ggml-small`, and no accuracy
figure here comes from real rather than synthesized speech.

### Whisper base against Apple, same corpus

Same machine, same renderer, same conditions, so the two are comparable.
Reproduce with `VOXSCRIPTA_CORPUS=1 swift test --filter
CorpusMeasurementRun/whisperEveryCondition`.

| Condition | Apple en | Whisper en | Apple es | Whisper es |
|---|---|---|---|---|
| clean | 1.3% | **0.6%** | 2.7% | 4.7% |
| quiet, −18 dB | 1.3% | 0.6% | 2.0% | 4.7% |
| hum, 12 dB SNR | 1.3% | 0.6% | 2.7% | 3.4% |
| music bed, 10 dB SNR | 1.3% | 0.6% | 2.0% | 4.0% |
| machinery, 6 dB SNR | 1.9% | 1.9% | 4.7% | **10.1%** |
| broadband hiss, 12 dB SNR | 3.8% | **2.5%** | 5.4% | **12.8%** |
| 3 s pauses | 5.1% | **3.8%** | 2.0% | 5.4% |
| abrupt ending | 1.3% | 0.6% | 2.7% | 4.7% |
| decaying final word | 1.3% | 0.6% | 2.7% | 4.7% |

**The better engine depends on the language, and nothing in the app knows
that.** Whisper base halves Apple's English error on clean audio and beats it
under hiss and under pauses as well. On Spanish it is about 1.7× worse clean,
and the gap widens hard under noise — 12.8% against 5.4% under hiss, 10.1%
against 4.7% under machinery. Engine selection is compile-time today
(`JobRunner` prefers Apple's where it exists), so a Spanish speaker on a
platform that falls to Whisper gets more than twice the error, and nothing
measures or surfaces it. This is the concrete case for making selection
language-aware, which §9's `EngineCapabilities` gap otherwise describes only in
the abstract.

**Whisper's Spanish falls off faster, not just from lower down**: 2.7× its own
clean rate under hiss, against Apple's 2×. That matters because the platforms
Whisper exists to serve — Windows, Linux, Android — are precisely the ones with
no Apple engine to fall back to.

**Long pauses produce insertions in both engines**, which is the more
interesting half of that row. Apple is a streaming recogniser, so its
insertions are plausibly premature finalization. Whisper is a batch engine and
cannot finalize prematurely, yet it also inserts — two insertions, no
deletions. Two unrelated mechanisms producing the same failure on the same
input means the pause problem is not one engine's design artefact. Pauses are
what the chunk planner cuts on.

**The accented Spanish verbs fail in both engines, worse in Whisper.**
`preguntó`, `escuchó`, `oscurezca` and `notó` are lost in most Whisper rows,
all final-stress forms carrying a written accent; Apple loses `preguntó` and
`escuchó` too. A consistent, nameable weakness rather than scattered error.

Three caveats so the table is not over-read: this is `ggml-base`, the smallest
multilingual model, and `ggml-small` has not been run and may change the
Spanish picture; it is synthesized speech on one machine; and real-time factor
came out at 0.01 for both engines, so none of this is a speed argument.

### Beam search against greedy, Whisper base

The engine decoded greedily, `best_of` 1, from the day it was added, and
nothing had measured what that cost. The reasoning recorded in the code was
determinism — resume and the content-hash cache both require that the same
audio yields the same transcript. That reasoning was sound and the conclusion
did not follow: **temperature 0 is what makes the decode deterministic, and
beam search at temperature 0 is just as deterministic as greedy.** Determinism
never required greedy.

| Condition | en greedy | en beam 5 | es greedy | es beam 5 |
|---|---|---|---|---|
| clean | 0.6% | **0.0%** | 4.7% | **4.0%** |
| quiet, −18 dB | 0.6% | 0.6% | 4.7% | **1.3%** |
| hum, 12 dB SNR | 0.6% | 0.6% | 3.4% | **2.0%** |
| music bed, 10 dB SNR | 0.6% | 0.6% | 4.0% | **3.4%** |
| machinery, 6 dB SNR | 1.9% | 1.9% | 10.1% | **8.1%** |
| broadband hiss, 12 dB SNR | 2.5% | 2.5% | 10.7% | **10.7%** |
| 3 s pauses | 3.8% | **3.2%** | 5.4% | 5.4% |
| abrupt ending | 0.6% | **0.0%** | 4.7% | **4.0%** |
| decaying final word | 0.6% | **0.0%** | 4.7% | **4.0%** |

**Spanish improves in every condition, and in one of them by 3.6×** — quiet
speech goes from 4.7% to 1.3%. English clean, abrupt-ending and decaying-tail
all reach 0.0%: the whole 149-word reference transcribed exactly. English under
noise is unchanged, which says the noise conditions defeat the acoustic model
rather than the search, and no amount of search fixes that.

The cost is a real-time factor of 0.01 moving to 0.02 — still around fifty
times faster than playback. So this was accuracy left on the table for nothing,
and beam search with a beam of 5 (whisper.cpp's own default) is now
`Decoding.standard`.

`VOXSCRIPTA_WHISPER_DECODING` takes `greedy` or `beam<N>` to reproduce either
row without an edit. The mode is part of `modelIdentity`, and therefore part of
the transcription stage's cache key, because a beam-search transcript and a
greedy one are different outputs from the same audio — serving one for the
other is the same stale-chunk bug that putting the model name in that string
was meant to prevent.

Against Apple's engine, the picture after this change: Whisper now beats Apple
on **every** English condition, and on Spanish in quiet and hum, while Apple
remains substantially better on Spanish under broadband hiss (5.4% against
10.7%) and machinery noise (4.7% against 8.1%). The next section closes that
last gap and with it the case for routing between engines.
### ggml-small against ggml-base, beam 5

The decisive result, and the one that settles the engine question.

| Condition | base en | small en | base es | small es | Apple es |
|---|---|---|---|---|---|
| clean | 0.0% | **0.0%** | 4.0% | **0.7%** | 2.7% |
| quiet, −18 dB | 0.6% | **0.0%** | 1.3% | **0.7%** | 2.0% |
| hum, 12 dB SNR | 0.6% | **0.0%** | 2.0% | **0.7%** | 2.7% |
| music bed, 10 dB SNR | 0.6% | **0.0%** | 3.4% | **0.7%** | 2.0% |
| machinery, 6 dB SNR | 1.9% | **1.3%** | 8.1% | **2.0%** | 4.7% |
| broadband hiss, 12 dB SNR | 2.5% | **1.3%** | 10.7% | **2.7%** | 5.4% |
| 3 s pauses | 3.2% | **1.3%** | 5.4% | **0.7%** | 2.0% |
| abrupt ending | 0.0% | **0.0%** | 4.0% | **0.7%** | 2.7% |
| decaying final word | 0.0% | **0.0%** | 4.0% | **0.7%** | 2.7% |

**Small beats both base and Apple's engine on every condition in both
languages.** Six of the eighteen cells reach 0.0% — the whole 149-word
reference transcribed exactly. Spanish under hiss falls from 10.7% to 2.7% and
under machinery noise from 8.1% to 2.0%; English long-pause error halves.

This **retires language-aware engine selection** rather than solving it. The
case for routing was that Apple won on noisy Spanish; with small there is no
condition in the corpus where routing to Apple's engine wins. A problem that
dissolves is better than a problem that is solved, and the selection code that
was about to be written is not needed.

The costs are a real-time factor of 0.01 moving to 0.03 — still around thirty
times faster than playback — and 141 MB of weights becoming 465 MB.
`defaultModelURL()` therefore prefers `ggml-small.bin` and falls back to
`ggml-base.bin`, so a checkout that fetched only base still works. Which model
*ships* stays a per-platform decision: 465 MB is a different proposition inside
an iOS download than inside a desktop install.

Memory is now the binding constraint rather than speed, and it is the number to
watch on a phone. Two things were learned about it here. Each Whisper context
costs roughly three times the model file, so one small context is about 1.4 GB
resident against base's 430 MB. And the language probe used to load the model
once per candidate language, which the Android session caught as three
`loading model` sequences inside one ten-second job; that is fixed, and the job
now loads twice — once to detect the language, once to transcribe.

Not yet measured: whether `ggml-medium` improves on small (the gaps left are
small enough that the corpus may not resolve it), and real-time factor and peak
resident size on ARM hardware, where the hundredfold speed headroom measured on
a Mac cannot be assumed.




---

### Merge cost, and the two bugs found measuring it

Chunking is free. Measured by transcribing the same recording twice — once
whole, once through the real planner, scheduler and merger — so the difference
is the seam and nothing else:

| Case | chunks | whole | chunked | delta |
|---|---|---|---|---|
| `en_long_with_pauses` (15.7 min) | 4 | 1.07% | 1.11% | +0.04 |
| `en_long_gapless` (12.1 min) | 3 | 0.87% | 0.75% | −0.12 |
| `es_long_gapless` (12.1 min) | 4 | 2.52% | 2.44% | −0.08 |

Eight seams across the three. On references of roughly 1,900 words a single
error is about 0.05 points, so every delta here is one or two words and two of
the three are negative. The honest reading is that the merge costs nothing
measurable, not that chunking improves accuracy.

That result was not available until two bugs were fixed, and **both made long
recordings fail outright** — the merger's ordering check threw rather than
shipping a corrupt transcript, so the symptom was no output rather than bad
output. Together they meant no recording needing more than one chunk could be
transcribed with Whisper at all, which is to say anything over about four
minutes.

**An engine reporting past the end of its own chunk.** Whisper's timestamps are
quantized and the last segment of a window can land beyond the audio it was
given: chunk 0 covered 0.00–242.86 s and reported a segment ending at
243.32 s. The next chunk began at 242.86, so the merged sequence went
backwards. Fixed in `ChunkScheduler.clamped`, which holds every engine's
segments inside the chunk they came from — the constraint belongs to the chunk
rather than to any engine's idea of time, so one implementation covers engines
not yet written. Times are clamped and nothing is discarded: the engine heard
only that chunk's audio, so the words came from inside it whatever the clock
says, and dropping them would turn a timing error into missing words.

**A word still being spoken across the splice.** On a hard cut the following
chunk overlaps by three seconds and the merger deduplicates. It kept words
ending after the cut — correct — but then took the trimmed segment's start from
the first surviving word, which begins *before* the cut. Chunk 1's first
segment started at 299.940 where chunk 0 ended at 300.000, a 60 ms overlap
created entirely by that line. `trimByTime` now clamps the start to the cut,
which keeps the word and moves only the claim about when the segment begins.

The ordering check's message now names the offending pair, their chunks and the
overlap in seconds. "Not in ascending time order" on its own cost two
measurement runs spent guessing, because an engine overshooting its chunk and
an overlap that was not deduplicated look identical from outside and need
unrelated fixes.

Neither bug was reachable by the existing tests. There was one asserting that
chunked and single-chunk output are byte-identical, but it ran on audio short
enough to plan as a single chunk either way, so it exercised the plumbing and
never the seam. The corpus cases are now sized from `ChunkParameters` rather
than from taste — the planner targets 240 s and hard-cuts at 300 s, so a
three-minute case plans as one chunk and measures nothing — and the measurement
fails rather than warns when a case produces a single chunk, because a passing
test printing deltas of +0.00 reads like a result.


### Language detection never fires

`LanguageProbe` transcribes a 20-second sample from the midpoint of the speech
in each candidate language and takes the winner if its confidence-weighted word
count beats the runner-up by a factor of three. Measured across five cases on
both engines, it chose a language **zero times out of ten**:

| Case | Apple margin | Whisper margin |
|---|---|---|
| `en_clean` — pure English | **1.06×** | 1.86× |
| `es_clean` — pure Spanish | 2.73× | 1.16× |
| `mixed_en_then_es` | 1.42× | 1.25× |
| `mixed_es_then_en` | 1.05× | 2.65× |
| `mixed_es_dominant` | 1.74× | 1.13× |

Required: 3.0×. Reproduce with `VOXSCRIPTA_CORPUS=1 ./Tools/test.sh --filter
MixedLanguageMeasurement`.

The controls are the finding. On **pure English** audio Apple's engine scored
en-US at 59.8 and es-ES at 56.7 — a margin of 1.06, meaning it transcribed
English as Spanish with 0.93 confidence and produced the same 61 words either
way. Word counts carry almost no signal: Whisper returned 62 Spanish-ish words
for English audio against 61 correct ones. Confidence discriminates better
(0.97 against 0.51) but not by threefold, and `weighted = words × confidence`
dilutes it by multiplying through a term that is nearly constant.

**This is the mechanism working as specified, which is the problem.** The
margin was deliberately set to 3.0, and the reasoning recorded on it is sound:
a field recording had produced 37 English words against Spanish audio where the
right language gave 50, and "a ratio of 1.35 is not a detection" — so the
threshold exists to refuse exactly the kind of ratio seen above. The probe is
not misfiring. It is declining, every time, as designed. The consequence is
that it costs two extra transcriptions of a 20-second sample on every job and
has never returned an answer on any audio that has been measured.

**What this corpus cannot settle.** The audio is synthesized, and that is the
best case for cross-language transliteration: a synthesizer reading Spanish
produces clean, canonical phonetics that an English model can map onto English
words with confidence. The real recording cited in the probe's own
documentation behaved quite differently — Spanish audio asked for as `en-US`
returned "fifty-three characters of commas and no words at all". So these
numbers establish that the probe declines on synthesized speech; they do not
establish that it would decline on real speech, and the corpus cannot be made
to answer that because the property that makes it reproducible is the same one
that makes it easy to transliterate.

**Mixed-language behaviour, which was the question asked.** For a recording
that changes language halfway, the midpoint sample lands on the seam and the
probe sees roughly ten seconds of each language — so the two scores come out
close and it declines. For `mixed_es_dominant`, two thirds Spanish with an
English passage in the middle, the sample lands on the English passage, and
Spanish still edges it (1.74× on Apple, 1.13× on Whisper) without reaching the
threshold. So the feared failure — confidently reporting English for a mostly
Spanish recording — does not occur. The probe declines instead, and falls back
to the user's own setting, which for a bilingual recording is the defensible
answer.

**The fix for Whisper is not a better threshold.** `whisper_lang_auto_detect`
exists in the C API: it reads the model's own language head from the mel
spectrogram and returns a probability for every language it knows, at the cost
of one encoder pass and no decoding at all. That is both cheaper than the
current two transcriptions and a direct measurement rather than an inference
from how many words came out. Whisper is now the default engine, so this is the
path worth taking; Apple's engine has no equivalent and would keep the probe.
Not yet implemented.

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
