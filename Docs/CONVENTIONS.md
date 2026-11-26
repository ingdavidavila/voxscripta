# How we change this code

`ARCHITECTURE.md` says why the system is built the way it is. This says how to
change it without making it worse.

Every rule below is here because it was broken, in this repository, and the
break cost something. None of it is general advice — each one names the
incident, so a reader can judge whether the rule still earns its place. Where a
rule was argued down or sharpened by the other session working this repo, it
says so, because the argument is part of why it is phrased this way.

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
