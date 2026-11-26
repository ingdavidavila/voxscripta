# Working on Vox Scripta

Read `Docs/CONVENTIONS.md` before changing code. It is sixteen rules, each
naming the incident in this repository that produced it. This file is the short
version that has to be in front of you every session.

## Before you start

- **`Docs/ARCHITECTURE.md`** — why the system is built this way.
- **`Docs/CONVENTIONS.md`** — how to change it without making it worse.
- **`Docs/PARITY.md`** — the feature contract between the two interfaces.
- Two sessions work this repository, on a Mac and on Windows, and two
  different people approve their pushes. Assume the other session is mid-task.

## Running things

**Tests: `Tools/test.sh`, never `swift test` directly.** The Xcode build system
signs each `.xctest` bundle and tracks its contents, so the MLX metallib placed
beside the binary makes the *next* build fail to re-sign. The script clears the
injected copies, builds, places the metallib, then tests. Running `swift test`
yourself fails with a codesign error that does not name its cause.

**Chain gates with `&&`. Never judge one through a pipe.** `… | tail` reports
the exit status of `tail`. This has been got wrong twice, once into a `git push`
with four findings on screen, and the second time reporting a release build as
succeeding when it had died on the localization gate.

The gates, all of which must pass before a push:

```
Tools/test.sh && Tools/check-abi.sh && Tools/check-localization.sh \
  && (cd flutter/app && flutter analyze) && Tools/check-conventions.sh
```

**Building for the iOS simulator needs `VOXSCRIPTA_IOS_SLICE=sim` *and* cleared
derived data.** Setting the variable alone is not enough — Xcode bakes the
resulting linker flags into its build description and reuses them. See the trap
written up in `Docs/RELEASE.md`; it cost four builds before anyone understood
it.

## Reporting

**Say where the work is: local, pushed, or on main. Never "done".** Work
reported as done has repeatedly been done locally while the other session
planned around it as though it had landed.

**Say what you did not run.** A green suite on one platform is not a green
suite. The Windows session cannot run the Swift tests; this machine cannot run
Android or a real GPU.

**Never claim a test passed without running it, and never invent a benchmark
number.** Where something is unverified, write that it is unverified.

## Things that are easy to get wrong here

- **Apple is not the normal case.** Apple platforms use the OS recogniser and
  ship no speech model; everything else uses whisper.cpp and must carry one.
  Four defects in one week existed only off Apple and were invisible on the
  machine where the suite is green.
- **The test corpus is all clean speech.** `jfk.wav` is byte-identical across
  backends; real disfluent speech is not. A change that looks safe against the
  fixtures may not be.
- **Original audio is never modified, moved or deleted.** Not by a fix, not by
  a cleanup, not by a test.
- **No network in the transcription path.** CI asserts this mechanically; keep
  it that way.
