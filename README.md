# VoxVerba

Local-first audio transcription for Apple Silicon Macs.

Drop in a recording. VoxVerba analyses it with deterministic signal processing,
transcribes it with an on-device speech model, reassembles one continuous
transcript, and optionally uses a local language model to produce clean and
polished versions — without changing what the speaker actually said.

**The original audio is never modified. Nothing leaves the Mac.**

---

## Status: Phase 4 — CLEAN, with no model

Verbatim and Clean are both complete, and no language model is involved in
either. The LLM is confined to POLISHED, which is Phase 6.

Implemented:

- **`CleanProcessor`** — filler removal, stutter collapse, punctuation repair,
  capitalization, and sentence termination, all deterministic.
- **`DisfluencyLexicon`** — a deliberately narrow closed set, with explicit
  protection for affirmations and legitimately doubled words.
- **`CleanEdit`** — an audit log of every change, written to
  `Output/clean_edits.json`.

206 tests across 38 suites.

### Why CLEAN is safe, and how that is checked

Two mechanisms, because "it carries no hallucination risk" is worthless as an
assertion:

**A structural invariant.** Every token in the CLEAN output must appear in the
verbatim transcript *in the same order* — output words are a subsequence of input
words. A pass satisfying this cannot have invented, substituted or reordered
anything. It is property-tested over adversarial cases and over real engine
output.

**An audit log.** The number of logged deletions must exactly equal the drop in
word count, so nothing can be removed silently.

The lexicon covers non-lexical vocalizations only. "basically", "probably", "you
know" and "I mean" are real words that shade meaning, and §12's own example keeps
them. "uh-huh" and "mm-hmm" are protected — deleting one can invert an answer.
"had had" and "that that" are never collapsed.

### What reviewing real output caught

The gate requires inspecting actual recordings, and that was not ceremonial. Run
against genuinely spoken disfluencies, the first implementation produced:

```
we should, um, start   ->   we should, start      (stranded delimiter)
I, I wanted            ->   I, wanted             (kept the stumble)
```

Both read as comma splices. Neither appeared in unit tests built from clean
hand-written transcripts — they only showed up against real engine output, where
punctuation arrives attached to tokens. Now:

```
Ah, so I think we should, um, start on Monday if that works.
So I think we should start on Monday if that works.
```

Try it:

```
swift run corpus-gen /tmp/vv-dis --speech 1 --disfluent
swift run voxverba-cli run /tmp/vv-dis/speech.wav --project /tmp/p --variant clean
```

`Output/clean_edits.json` lists every change the pass made.

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
