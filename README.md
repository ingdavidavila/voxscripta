# VoxVerba

Local-first audio transcription for Apple Silicon Macs.

Drop in a recording. VoxVerba analyses it with deterministic signal processing,
transcribes it with an on-device speech model, reassembles one continuous
transcript, and optionally uses a local language model to produce clean and
polished versions — without changing what the speaker actually said.

**The original audio is never modified. Nothing leaves the Mac.**

---

## Status: Phase 5 — the validation gauntlet

Built deliberately **before** the language model. The fence goes up before the
gate opens.

All seven checks from §14 are implemented and graded by mutation testing: known
good output is corrupted one damage class at a time, and **a corruption that
survives the gauntlet is a test failure**. That turns "does it hallucinate?" from
a worry into a deterministic assertion.

| Check | Catches |
|---|---|
| Cardinality | merged, dropped or invented sentences |
| Numeric conservation | `500` becoming `approximately 1,000` |
| Named-entity conservation | renamed, dropped or invented people and firms |
| Polarity | `did not approve` becoming `approved` |
| Modality | a hedge dropped, making a qualified claim absolute |
| Semantic similarity | wholesale meaning replacement |
| Extent bounds | summarization and invented padding |

19 mutations across 7 damage classes, all caught, each by the check that owns it.
6 legitimate polish pairs, none rejected — a validator that refuses good output
would make every window fall back to CLEAN and POLISHED would do nothing.

224 tests across 41 suites.

### What measurement changed

Three assumptions did not survive contact with the on-device models.

**The similarity check works in distance, not cosine.** `NLEmbedding` reports a
distance where lower is closer, on a scale running past 1, so the architecture's
"cosine ≥ 0.85" was meaningless against it. The threshold is now **0.72 maximum
distance**, placed in the middle of a measured gap: legitimate polish tops out at
0.548, the closest real corruption sits at 0.904.

**Case folding before embedding is load-bearing.** Capitalizing a sentence moves
this model almost as far as inverting its meaning — 0.86 for `david met sarah
chen` vs `David met Sarah Chen`, against a 0.90 floor for genuine corruption.
Since fixing capitalization is exactly what POLISHED is for, comparing raw text
spends the whole error budget on an artifact. Folding case widens the margin from
0.028 to 0.356 — twelve times.

**The embedding check alone would miss most of what matters.** Measured drift for
changing a number (0.43), renaming a person (0.24) or dropping a hedge (0.42) all
sit far below the threshold — small, fluent, local edits that barely move a
sentence vector, and precisely the transformations §14 exists to prevent. Only
the specific conservation checks catch them. A test asserts this stays true, so
nobody later "simplifies" the gauntlet down to one embedding comparison.

The named-entity check had to be rebuilt around the tagger's real behaviour: it
labels `David` a place name and misses entities outright, so comparison is by
string and never by type. Capitalization decides only *which* tokens to watch;
the comparison itself is case-insensitive, or fixing `david` → `David` would read
as adding a name.

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
