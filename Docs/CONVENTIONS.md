# How we change this code

`ARCHITECTURE.md` says why the system is built the way it is. This says how to
change it without making it worse.

Every rule below is here because it was broken, in this repository, and the
break cost something. None of it is general advice — each one names the
incident, so a reader can judge whether the rule still earns its place. Where a
rule was argued down or sharpened by the other session working this repo, it
says so, because the argument is part of why it is phrased this way.

A rule's number is its name, not its position. New rules are appended to the
section they belong to and take the next unused number, so numbering runs out of
order down the page. That is deliberate: `check-conventions.sh` cited "rule 12"
for two of rule 13's clauses, because the rule it meant had been renumbered
under it — rule 15's own disease, caught in the script that enforces these. A
number that never moves cannot go stale, and the citation check at the bottom of
`check-conventions.sh` now proves every reference in `Tools/` still lands on the
rule it names.

---

## Invariants and contracts

### 1. A rule written in a comment is not a rule

`WhisperEngine` carried this, directly above the code that violated it:

> Whisper's tokens are sub-word pieces, not words. They are kept because
> subtitle export needs timings, but they are not a word list and nothing
> should treat them as one until they are merged.

Nothing merged them. Three files away, `CleanProcessor` joined them with spaces,
and real transcripts read `nov ice`, `sub red dit`, `code c ad emy`, `20, 000`.
The invariant was stated, agreed, documented — and unenforceable, so it was
false.

**Make the invariant true in a type or a test, then write the comment.** If the
only thing holding a rule up is that the next person reads the paragraph, it is
already broken somewhere nobody has looked.

### 2. Exhaustive switches on types we own; elsewhere, a default is a decision

`VoxScriptaError.code` switches over every case with no `default`. Adding an
error will not compile until someone gives it a code — the only mechanism
stopping a new error shipping untranslatable.

This was first written as "never `default:`" and argued down, correctly. On a
set someone *else* can extend — wire values, a newer engine's states — a default
is honest, provided it is a named decision that fails closed and has a test
naming it. `EntitlementState.fromWire` maps an unknown state to `trialExpired`:
an unrecognised future state refuses service rather than granting it.

**No default on a closed type we own. On an open set, the default is a decision
with a test — not a shrug.**

### 3. One home per rule, exported across boundaries

The export filename convention — `<base> — <variant>.<ext>`, an em dash with
spaces, which nobody guesses — lived only in `VoxScriptaExport`. The Flutter
interface was about to rebuild it, and would have drifted the first time it
changed, silently, because nothing compared the two.

`vs_export`'s own comment had the principle: *one entry point for all five
formats means the interface never learns how any of them is built.* The filename
sat outside that guard until `vs_export_filename` was added.

**If a rule must be known across the FFI, export it.** A second implementation
is not duplication to tidy later; it is a divergence with a date on it.

### 4. An unused exported symbol means one of two opposite things

Both sessions audited this repository for dead code on the same day. The Swift
side had three unused `public` declarations in 26,000 lines; the Dart side
looked up all 41 ABI symbols and found four with no application caller. Two of
those four looked identical in the count and were opposites.

`vs_recording_new_path` really is surface nobody needs: `vs_recording_start`
generates a path when given none, and Dart never builds one.

`vs_export_options_defaults` is the reverse. `PARITY.md` says *"the engine
reports its own defaults… a settings screen with its own hardcoded default
silence margin is a rule living in an interface"*, and that symbol exists to
enforce it. Dart does not call it — it carries `_includeTimestamps = false`
while the engine carries `includeTimestamps: Bool = false`. **They agree by
coincidence, not by construction.** Its non-use is the defect, and deleting it
would have made the duplication permanent.

**A usage count cannot tell the two apart. Look at what the caller does instead
of calling it** — nothing, or the same thing again in its own words.

### 5. Record what happened, not what was configured or shipped

The sharpest version of this came from the Vulkan work. The obvious design was
to record which DLL loaded. But the Vulkan DLL with GPU drivers hidden produces
output byte-identical to the CPU DLL — so the DLL name is a fact about the
build, and the thing that changes the transcript is **the compute device
actually used**, which only the engine can report at context init.

Same shape as rule 1: a field describing intent drifts from behaviour the moment
the two can differ. Provenance, logs and resume hashes record what the run did.

**Ask the component what it did. Never infer it from how it was built.**

### 6. A field joins a contract defaulted-empty — for old data only

`modelIdentity` joined the resume hash defaulted to `""`, so every engine
without weights and every existing project hashed exactly as before. That is why
adding it invalidated nobody's cache.

This collides with rule 4, and the collision is real: a defaulted-empty field
that a *live* caller forgets to populate is precisely rule 4's plausible
default — a GPU run silently hashing as CPU. The resolution:

**Empty means exactly the old behaviour, for data written before the field
existed. Anything that can know the real value has no default to fall back on**
— a protocol requirement with no default implementation, so a new engine cannot
compile without answering.

### 18. A flag that reads like the guard may be aimed at another mechanism

`WhisperEngine` pinned `params.translate = false` under a comment saying a
transcript is a record of what was said and Vox Scripta will not silently return
it in another language. The comment states the right invariant. The flag does
not enforce it: `translate` governs translation *to English* and says nothing
about the other direction, so a decoder conditioned on a mismatched language
token still wrote fluent Spanish over English audio, and fluent English over
Spanish audio, with the flag off the whole time. Found on Windows and Linux, in
both directions, on both model sizes.

The damage is the shape to remember. VERBATIM read perfectly, in whole
sentences, of words nobody said. CLEAN and POLISH then saw internally consistent
prose, and the validation gauntlet compares a revision against *that prose*
rather than against the audio, so nine checks passed on a transcript with no
relationship to the recording. Every downstream reader of a guarded value
inherits the guard's blind spot.

**Test the invariant, not the flag.** A flag is evidence about configuration; a
test that feeds the mismatched input and asserts the output is evidence about
behaviour. Where the invariant can only be checked against something outside the
text — here the audio — that check has to exist even when it costs an extra pass,
because nothing inside the text can stand in for it.

### 20. Do not store a marker on the thing its own condition destroys

The wrong-language warning was appended to `segments[0].warnings`, because
`warnings` was a segment field and nothing else existed. CLEAN then dropped
that segment for scoring below its confidence floor and took the warning with
it; on one recording it dropped every segment and returned an empty transcript
with no warning at all, while the recognised speech sat in VERBATIM beside it.

The part worth keeping is not the bug, it is why it was certain to happen.
Decoding speech against the wrong language is *what produces* low confidence.
The note was therefore pinned to precisely the segment that the condition it
describes was most likely to remove — so the warning disappeared exactly when
it was needed and survived whenever it did not matter. A test with ordinary
confidences passes every time. The Windows session found it by running real
mismatched audio, which is the only input where the two conditions coincide.

**Ask what removes the carrier, and whether the same cause removes it.** A flag
about a failure must not live inside the thing the failure damages: a note about
the whole recording belongs on the transcript (`Transcript.notes`), not on a
segment. Where a marker must share a lifetime with its subject, the test has to
use an input that triggers both at once, because independent inputs will not.

And the second half, which is a rule of its own shape: **a derived output must
not become empty in silence.** CLEAN now refuses to hand back nothing when
VERBATIM had something, and says which floor removed what.

---

## Platforms and builds

### 7. A fix for one platform must be proven not to change the others

`_fileName` was changed to split on `[\\/]` so Windows paths worked. Backslash
is legal in a macOS or Linux filename, so `my\recording.m4a` began truncating to
`recording.m4a` — breaking three platforms to fix a fourth.

The fix was right; its scope was not. `fileNameOf(path, windows:)` takes the
platform as a parameter, so both behaviours are testable from any host.

**Take the condition as an argument** rather than reading the ambient platform
inside the function. One machine then tests every branch.

### 8. What changes *what* is built changes *where* it is built

A manifest that reads an environment variable — `VOXSCRIPTA_IOS_SLICE`,
`VOXSCRIPTA_VULKAN` — produces a different build from the same source. Xcode
caches the resulting linker flags in its build description, and SwiftPM and
CMake cache elsewhere again, so the second build silently reuses the first and
fails with the identical error that made someone set the variable. That trap
cost four builds before it was understood, and is written up in `RELEASE.md`.

**Every build variant gets its own scratch and output directory.** Not a cleaned
one: its own.

### 9. A new native dependency is a delivery change

Linking something new is the easy half. The questions that bite are whether the
binary's import table names what you think, and what happens on a machine
without it.

The Vulkan work tested this properly: the GPU DLL's import was patched to a
nonexistent `vulkan-9.dll` to prove the CPU one loads instead, and the drivers
were hidden to prove it finishes on CPU.

**Read the import table, and test the failure to load — not only the success.**

### 10. An optional input on a search path changes behaviour silently

A `polish.gguf` left in `build/models` made every run polish, turning a
five-minute file into a fifteen-minute one, with nothing on screen saying why.
`ModelSearch` walking up from the working directory is right for development and
is exactly the mechanism that makes this invisible.

**A run records which optional inputs it found. Tests take none from a
developer's build tree.**

### 19. One gate passing while another cannot compile is an environment signal

`swift build` was clean and `Tools/test.sh` failed with 28 × `no such module
'Testing'`, in targets nobody had touched. It read exactly like a broken
checkout, and it cost a stash-and-rebuild at `HEAD` to establish that the working
tree was fine. The cause was `xcode-select` pointing at the Command Line Tools,
whose toolchain ships no swift-testing; the library compiles because nothing in
it imports `Testing`, so only the tests break.

**Before reading the code, check what the failure cannot be.** A diff cannot
break a module import in a file it does not touch. `Tools/test.sh` now detects
this case and names it, searching for an Xcode rather than hardcoding one — that
path being baked in was one of the three faults that kept CI from ever passing.

---

## Tests

### 11. Inject the dependency rather than mutate a global

The first `ModelSearch` tests set the process-wide data directory and raced each
other — a global is global, so a test that mutates it is testing every test
beside it. Passing the directory removed the race, the need for `.serialized`,
and the ambiguity about what was under test.

### 12. A fixture must resemble the input that breaks things

`jfk.wav` is byte-identical on CPU and Vulkan. Real disfluent speech differed by
24 tokens — fillers and stutters sitting near the decode threshold, which clean
recorded speech does not have.

So the divergence appears for every real user and in none of our tests, because
the corpus is entirely the clean case.

**We need a disfluent sample we have permission to commit.** Not anyone's
private recording without their say-so.

### 13. A check that cannot fail is decoration

Three ways this has happened here, all in one week:

- **Unwired.** CI had never passed once in the repository's history, and
  `check-localization.sh` was never invoked by anything — it had been failing
  locally for three weeks, which is why the macOS release bundle could not be
  built and nobody knew. `PolishModelComparison` sat disabled until its question
  became urgent.
- **Unable to stop what follows.** A gate run as `… | tail` reports the exit
  status of `tail`. Both of us have read a success from a pipe and continued —
  once into a `git push` with four findings on screen.
- **Judged by eye.** Reading a gate's output instead of its exit code.

**Chain gates with `&&`. Never judge one through a pipe.** An unwired or
unenforcing check is worse than none, because its existence is mistaken for
coverage.

---

## Working together

### 14. Delete the stopgap in the commit that replaces it

Android carried its own filename rule while `vs_export_filename` was written,
and deleted it the moment the real one landed, in the same change. A stopgap
with no deletion date is a permanent second home — rule 3, arriving by a route
that feels responsible.

### 15. Numbers in prose rot; put them where they are compared

`bindings.dart` opened with *"The thirty-three symbols of ffi/voxscripta.h"*. It
had been 38 for some time and is 41 now; wrong twice. The count lives in
`Tools/check-abi.sh`, where it is checked rather than remembered.

### 16. Green on two branches is not green on the merge

`windows-engine` and `whisper-words` each passed `flutter analyze`. Their merge
did not — four angle-bracket warnings in a doc comment, from a commit pushed
after the branch was reviewed. **Run the gates on the combination.**

### 17. Say where the work is, and what was not tested

Two sessions work this repository and two different people approve their pushes.
Work reported as "done" was repeatedly done *locally*, and the other session
planned around it as though it had landed.

**Say local, pushed, or on main — never "done" — and say what you did not run.**
Neither of us is above this; both of us have done it.

---

## A note on streamlining

Most of the above removes code rather than adding it: one implementation instead
of two, one entry point instead of a rule restated per caller, a parameter
instead of a global, a deleted stopgap. The shortest version of this document is
that **a second copy of a rule is the defect**, and most incidents here are that
defect wearing a different hat.

What streamlining is *not*: removing a check because it is inconvenient, or
collapsing a platform branch because it looks redundant on the machine in front
of you. Rules 7, 10 and 13 exist because both are tempting and both have already
cost us.
