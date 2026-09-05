# VoxVerba

Local-first audio transcription for Apple Silicon Macs.

Drop in a recording. VoxVerba analyses it with deterministic signal processing,
transcribes it with an on-device speech model, reassembles one continuous
transcript, and optionally uses a local language model to produce clean and
polished versions — without changing what the speaker actually said.

**The original audio is never modified. Nothing leaves the Mac.**

---

## Status: Phase 6 — POLISHED

The full three-output pipeline works, entirely on device. VERBATIM and CLEAN
involve no model; POLISHED runs Apple's on-device model behind the Phase 5
gauntlet, one sentence at a time.

| Corpus | Sentences | Rejected | Fell back | Rewritten |
|---|---|---|---|---|
| clean speech (121 s) | 20 | **15%** | **0%** | 40% |
| disfluent (65 s) | 15 | 33% | 33% | 33% |

On the clean corpus every rejection was recovered by the retry — nothing fell
back. Numbers, names, negations and hedges all survive: `500`, `312`,
`Sarah Chen`, `did not approve`, `has not scheduled`, `might be`, `probably`.

232 tests across 41 suites.

### The measurement that reshaped the design

The architecture specified windows of three to eight sentences. It is now **one**,
and the path there is worth recording.

Guided generation constrains a response's *shape*, not an array's length, so the
model merged sentences freely — two thirds of windows rejected on cardinality
alone, each rejection costing every sentence in its window. Building the schema
at runtime with `minimumElements == maximumElements` fixed the count and produced
a **worse** failure: forced to return five items for five inputs, the model
merged two and then shifted and duplicated the rest to fill the array. Right
length, destroyed alignment.

```
3. "We did not approve it."          → "We did not approve it because the numbers were wrong."
4. "Because the numbers were wrong." → "Aha, that is right, and we sold 500 units."
5. "Aha, that is right..."           → "We did not approve it because the numbers were wrong."
```

At one sentence per call, merging and shifting are structurally impossible and a
rejection costs exactly one sentence. Rejection fell from 100% to 15%.

### Two gaps the real model exposed

**Retention cannot catch injection.** "Start on Monday if that works" becoming
"Let's start on Monday if that works *for you*" keeps every original content word
and still adds a referent the speaker never mentioned. The extent check now
bounds additions as well as losses.

**"I" is not a proper noun.** It is always capitalized in English, so the
capitalization heuristic treated it as a name and rejected every sentence
containing the pronoun.

### Scope note

The MLX backend is not built. It needs `mlx-swift-lm`, a large dependency fetched
over the network at build time, which would end this project's zero-dependency,
offline-buildable property. The system model is sufficient for one-sentence
windows, so MLX is a quality tier rather than a prerequisite;
`LanguageModelHosting` is the seam.

Rejection rates were measured on one- and two-minute recordings, not multi-hour
ones. Polish costs roughly a second per sentence, so an hour of speech would be
about ten minutes — projected, not measured.

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
