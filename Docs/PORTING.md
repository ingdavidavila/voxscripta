# Porting to Android, Windows and Linux

Five apps are wanted: iPhone, Android, Mac, Windows, Linux. The phones should
match each other and the desktops should match each other. This records how,
what it costs, and one decision that reverses an earlier one.

## What was decided

| Question | Decision |
| --- | --- |
| Interface | SwiftUI stays on Mac and iPhone. One Flutter interface serves Android, Windows and Linux. |
| Recognition and polishing | Apple's engines stay on Apple platforms. Everywhere else, whisper.cpp and llama.cpp. |
| Order | The portable engine first, proven on a desktop, before any new app is packaged. |

Two interfaces will drift apart unless something stops them. The guard is that
neither contains logic: every rule lives in the shared engine, and an interface
that needs new behaviour has to add it there, where both read it.

## The measurement that changes the plan

`Package.swift` has said since the Android spike that the C++ port replaces the
Swift module by module, with `VoxScriptaCoreParityTests` holding the two to the
same answers until each Swift module is retired. That was the right call when
Android was the only other target and the Android NDK was the only other
toolchain. It is the wrong call now, and the reason is a count.

Measured across `Sources`, by module, for Apple-framework imports:

| Already free of Apple frameworks | Lines |
| --- | ---: |
| VoxScriptaCore | 1,681 |
| VoxScriptaProject | 1,215 |
| VoxScriptaPipeline | 795 |
| VoxScriptaExport | 621 |
| voxscripta-cli | 802 |
| VoxScriptaBench + corpus-gen | 370 |
| **Total** | **5,484** |

Those are the job graph, the project format, the resume planner, every
exporter, and the command line — the whole spine. They import Foundation and
nothing else. A search for the Foundation APIs that Linux does not have found
**eight call sites**, all in `ProjectStore`, all security-scoped bookmarks or
Trash, and most already behind `#if os(macOS)`.

Against that, porting the engine to C++ means moving roughly 8,000 lines that
already work and are already tested, and then keeping two implementations
agreeing forever. The parity target exists precisely because that agreement
does not hold by itself.

Swift builds for Linux and Windows with official toolchains, and for Android
with the Swift SDK. So the recommendation is to **keep one Swift engine and
swap the four Apple backends**, rather than rewrite it in C++.

The 568 lines in `core/` are not wasted — they proved the Android NDK
toolchain, the four-ABI cross-compile and the JNI contract, which is exactly
the knowledge the packaging step needs. They stop being the plan of record.

## The four backends to replace

Everything Apple-specific sits behind an abstraction already, which is why this
is a swap rather than surgery.

| What | Today | Off Apple | Where it plugs in |
| --- | --- | --- | --- |
| Recognition | `SpeechAnalyzer` | whisper.cpp | `TranscriptionEngine` — four methods |
| Polishing | `FoundationModels`, MLX | llama.cpp | `LanguageModelHost` |
| Audio decode | `AVFoundation` | FFmpeg (LGPL v2.1), **done** | `CanonicalDecoding` |
| Recording | `AVCaptureSession` | miniaudio + FFmpeg, **done** | `PortableRecorder` |

Two more, smaller:

- **Accelerate** in the DSP. The algorithms are already deterministic and
  tested against synthetic ground truth; plain Swift carries them, with SIMD
  only where a measurement says it is needed.
- **`NLEmbedding`**, used for the semantic-distance check in the polish
  gauntlet. It is already known to contribute nothing in Spanish — the
  corpus proved the lexical checks catch every polarity inversion on their
  own — so the honest fallback is to run without it and have the check
  abstain visibly, which it is already built to do.

## The container gap, closed with FFmpeg

`PortableDecoder` reads what AVFoundation reads: wav, m4a, flac, caf, aiff,
mp3, and the audio track inside mp4 and mov. It converts to 16 kHz mono on
the way out, and it agrees with the Apple decoder to about one part in
seventy thousand — measured, on the same files:

| File | Offset | Worst difference |
| --- | ---: | ---: |
| WAV | 0 samples | 0.0000138 |
| m4a (AAC) | 0 samples | 0.0000415 |

This replaced a miniaudio implementation that read wav, flac and mp3 and
could not read AAC. That was not a rounding error in coverage: the app
records m4a, so a recording made on a Mac could not have been opened on
Linux. miniaudio stays in the tree for device IO, which is the next backend.

**The licence.** FFmpeg is built with `--disable-gpl --disable-nonfree
--disable-version3`, which makes it LGPL v2.1, and as shared libraries, which
is what keeps that satisfiable without publishing this app's source: the
libraries ship beside the binary and can be replaced. The build is cut down to
the demuxers and decoders listed above and nothing else — 2.9 MB rather than
the tens of megabytes a full FFmpeg is. `Tools/build-ffmpeg.sh` holds the
flags and prints the licence it produced.

On the Mac the libraries are copied into `Contents/Frameworks`, re-pathed to
`@rpath` and signed. Without that the app launches only on the machine that
built it, which is how this was found.

## Recording, and why the file format is the same everywhere

The portable recorder writes **the same fragmented m4a the Apple one does**,
because FFmpeg is already linked and enabling its AAC encoder and mov muxer
costs 400 KB. That is worth more than it sounds: a recording made on Android
opens on a Mac, the crash-safety mechanism is one mechanism rather than two,
and there is no second format for the pipeline, the exporters or the user to
know about.

miniaudio opens the capture device — WASAPI, ALSA or PulseAudio, AAudio,
CoreAudio — and is asked for exactly the format the writer wants, so no
conversion happens in this project's code. It is the only job miniaudio does
now; FFmpeg took over decoding.

Measured, by abandoning a half-written recording and reading it back with
this project's own decoder:

| | Recovered from 6 seconds |
| --- | ---: |
| Fragmented, abandoned mid-write | 4.04 s |
| The same file unfragmented | 0.00 s |

The two seconds missing are the fragment that was still in flight, which is
the interval working as intended rather than a loss to fix.

**Untested:** opening a real capture device. There is no microphone on a test
runner and faking one would test the fake, which is the same position the
Apple recorder is in. Everything around it — the file format, the crash
property, the transport, the meter floor — is covered.

## What this costs the user, stated plainly

Keeping Apple's recogniser on Apple means **the same recording can produce
different words on a phone than on a PC**. That is a real cost and it is not
hidden: `EngineID` is already written into every transcript's provenance, so
any two transcripts can be compared and the difference attributed.

The alternative — whisper.cpp everywhere — buys identical output at the price
of the Mac's measured 120× real-time speed and its current accuracy. That
trade was offered and declined.

## Linux: what builds, and what is left

Cross-compiled from a Mac with the swift.org 6.4.0 toolchain and the Static
Linux SDK. `Tools/build-linux.sh` runs it and lists the targets.

| Module | Linux |
| --- | --- |
| VoxScriptaCore | builds |
| VoxScriptaExport | builds |
| VoxScriptaProject | builds |
| VoxScriptaLanguage | builds |
| VoxScriptaDSP | builds |
| VoxScriptaTranscription | builds |
| VoxScriptaPipeline | **blocked on an MLX dependency** |
| CLI | waits on Pipeline |

The prediction that only eight call sites stood in the way was close but not
right. What actually had to change:

- **`OSLog`** — missed by the original survey, which grepped a fixed list of
  frameworks. Off Apple the logger is a silent stand-in rather than a `print`,
  because the Apple one marks user content `.private` and a substitute that
  printed would break that promise where it is least visible.
- **`String(localized:)`** — Apple-only Foundation. A gated shim returns the
  English the call site already holds, so the engine speaks English off Apple.
  The fix is not to rebuild string tables here: the Flutter interface should
  translate from the `VoxScriptaError` case, which carries the facts.
- **`SQLite3`** — a module Apple ships and nothing else does; the static Linux
  SDK has no libsqlite3 at all. The official amalgamation is now vendored and
  compiled for every target.
- **`CryptoKit`** — swift-crypto has the same API and was already in the graph.
- **`F_FULLFSYNC`** — Darwin-only, and the reason it exists is that macOS's
  `fsync` does not flush the drive cache. Linux's does, so plain `fsync` is
  the right equivalent rather than a weaker one.
- **Bookmarks and the Trash** — the eight that were predicted. Off Apple the
  source reference is the path, stored in the same field, and a deleted
  project moves to a `Deleted` folder beside the library so deletion stays
  recoverable. A project carried from a Mac holds a real bookmark, which is
  reported as unavailable rather than misread.

### Accelerate, replaced and measured

`PortableDSP` carries the six vDSP calls the analysis stage uses, including
the FFT. It is compiled on every platform rather than only off Apple, because
`PortableDSPParityTests` runs it against vDSP on the same input — so the
version Linux depends on is the version that was checked.

| | Agreement with Accelerate |
| --- | --- |
| Power spectrum | < 1e-4 relative, worst bin, sizes 256–1024 |
| Spectral flatness | < 1e-5 absolute — the number silence detection reads |
| Hann window | 6e-8 absolute |
| RMS, min/max, multiply | exact |

Three vDSP conventions had to be reproduced rather than improved on, because
the silence thresholds were calibrated against them: the real FFT returns
twice the mathematical transform, DC and Nyquist are packed into the same
complex slot, and `zvmags` therefore reports the sum of their squares as the
first "bin". A textbook implementation would have been quietly wrong.

### The pipeline dependency, inverted

`VoxScriptaPipeline` used to import `VoxScriptaMLX`, which is Apple Silicon
only and drags in a HuggingFace package that refuses to build against musl.
Gating the import was not enough, and neither was
`.target(name: "VoxScriptaMLX", condition: .when(platforms: [.macOS, .iOS]))`
— SwiftPM builds the target and its packages regardless.

The fix was the one the dependency direction already wanted. `PolishBackend`
moved down into `VoxScriptaLanguage`, which already owns both hosts it can
name, and grew a registration slot:

```swift
PolishBackendResolver.registerBundledHost { directory in … }
```

`VoxScriptaMLX` fills that slot — `MLXModelHost.registerAsBundledBackend()`,
called from `AppModel.init` — so the arrow runs downward everywhere and
nothing above the language layer names MLX. `VoxScriptaUI` now declares
`VoxScriptaMLX` directly, which it had been reaching only by accident, through
the pipeline.

**What changed behaviourally, stated rather than buried.** `.bundled` resolves
to whatever the process registered. The Mac and iOS apps register MLX at
launch, so they are unchanged. `voxscripta-cli` registers nothing — it has to
cross-compile — so `.bundled` there is llama.cpp reading a GGUF, and
`--model` now names that file rather than an MLX directory. Same prompt, same
cleaning, same gauntlet; `describedAs` records which library ran, and
`PolishBackendResolverTests` pins all of it.

Three smaller things had to be portable before the pipeline would compile:

| | Before | Now |
| --- | --- | --- |
| Decoder | `CanonicalDecoder()` named directly | `JobRunner.defaultDecoder` — AVFoundation, else FFmpeg |
| Locale probe | filtered by Apple's installed models | off Apple, whisper's one multilingual model covers every language the text stages support |
| `Log` shim | no `privacy:` interpolation | `LogMessage` accepts it and discards it, so call sites keep the qualifier on every platform |

That last one matters more than it looks. Dropping `privacy:` off Apple would
have left the same log line spelled two ways, and the two would drift until a
Mac build leaked transcript text into a sysdiagnose.

### What the command line still needs

Every Swift file in `voxscripta-cli` compiles for `aarch64-linux-musl`. It
does not link: FFmpeg, whisper.cpp, llama.cpp, miniaudio and SQLite have only
ever been built for the Mac, so the link stops at
`ld.lld: unable to find library -lavformat`. Cross-building those five is the
next piece of work, and it is a build-system job rather than a Swift one.

One CLI subcommand is genuinely absent off Apple rather than merely unbuilt:
`render-audio` writes the silence-removed copy through `AVFoundation`, so it
throws `notImplemented` by name. The time map it would ship beside the audio
is plain data and is produced everywhere.

### POLISH is weaker off Apple, and that needs deciding

Three gauntlet checks lose their backing where `NaturalLanguage` does not
exist, and they do not all lose it equally:

| Check | Off Apple |
| --- | --- |
| Semantic distance | abstains — no sentence embeddings |
| Named entities | degraded — capitalized tokens only, no tagger |
| Content-word overlap | degraded — surface forms, no lemmas, so **stricter** |

The middle one is the concern. English had two independent defences against a
reversed meaning: the lexical polarity count and the semantic distance. Off
Apple only the first remains — which is exactly the position Spanish has
always been in, and the Spanish rejection corpus measured that lexical checks
alone caught every polarity inversion. So there is evidence this is survivable,
gathered for a different reason.

What there is not, yet, is that evidence for English. Before POLISH is enabled
on Android, Windows or Linux, the English corpus should be run with the
embedding disabled, the way `PolishReadiness` already gates by measurement
rather than by assertion.

## Order of work

1. **whisper.cpp behind `TranscriptionEngine`, built and measured on the Mac.**
   It is portable C++, so proving it here proves it everywhere, and the word
   error rate can be compared directly against Apple's on the same fixtures
   that produced the 1.33% and 6.33% Spanish figures.
2. **llama.cpp behind `LanguageModelHost`**, validated against the existing
   rejection corpus rather than by inspection.
3. **A portable decoder**, checked against the container matrix the DSP tests
   already cover.
4. **Swift for Linux**, then Windows: build the spine, run the suite, fix the
   eight call sites.
5. **The Flutter interface**, against the engine through a C ABI.
6. **Android packaging**, reusing what the NDK spike established.

Each step ends with the existing tests passing against the new backend, not
with it compiling.

## Windows: what the ground looks like

Established on the development Mac on 2026-11-01, before any Windows code was
written. Recorded because the first finding changes who can do the work.

**Swift cannot be cross-compiled to Windows from this Mac.** The compiler
resolves the triple — `swiftc -print-target-info -target
x86_64-unknown-windows-msvc` answers with `"platform": "windows"` — but the
runtime it names,
`~/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain/usr/lib/swift/windows`,
does not exist, and `swift sdk list` offers only
`swift-6.4.0-RELEASE_static-linux-0.1.0`. There is no Windows equivalent of the
Static Linux SDK: a Windows build needs the MSVC toolset and the Windows SDK
headers and import libraries, which ship with Visual Studio on Windows. So
unlike Linux, Windows cannot be checked from here at all — it needs a Windows
machine or a Windows CI runner. That is a prerequisite, not a preference.

**Flutter is not installed**, and the Windows interface is a Flutter
application under the decision at the top of this document. `flutter` and
`dart` are both absent. CMake is present but not on `PATH`
(`/Applications/CMake.app/Contents/bin/cmake`); `ninja` is absent.

**The engine's platform conditionals mostly already cover Windows.** Every
non-Apple branch in the engine is spelled `#if !canImport(Darwin)` rather than
`#if os(Linux)`, so Windows takes the same path Linux does. Four files carry
one: `VoxScriptaBench/Benchmark.swift`, `VoxScriptaCore/Localization.swift`,
`VoxScriptaProject/AtomicFile.swift` and `VoxScriptaProject/ProjectStore.swift`,
plus `voxscripta-cli/CLI.swift`. Whether those branches use POSIX-only calls
that Windows lacks has **not** been checked — it is the first thing to audit,
and it cannot be settled by compiling here.

### The order this implies

1. **Audit the five `!canImport(Darwin)` branches for POSIX assumptions**, and
   the C libraries' build for MSVC. Doable here by inspection; not verifiable
   here.
2. **A C ABI over the Swift engine.** Flutter talks to Dart FFI, which talks
   to C. Nothing of this exists yet — the JNI in `android/jni/` belongs to the
   superseded C++ spike, not to the Swift engine. This is the piece Windows,
   Android and Linux all need, and it is the one piece that can be built and
   tested on this Mac today, on macOS and cross-compiled for Linux.
3. **The Windows build** of the five C libraries and the engine. Needs Windows.
4. **The Flutter application.** Needs Flutter; needs Windows to produce a
   Windows binary.

Step 2 is where to start, because it is the only one of the four that this
machine can finish and prove.

### Step 1, done: two Windows defects and a near-miss

`ProjectStore`'s non-Apple branches turned out to be pure Foundation — the
local Deleted folder that stands in for the Trash, and the path that stands in
for a security-scoped bookmark — so they carry to Windows unchanged. Two
others did not.

`Benchmark.current()` read `/proc/self/status`, which Windows does not have, so
every memory measurement would have thrown. It now uses
`GetProcessMemoryInfo`'s `WorkingSetSize`, with the same caveat the Linux
branch already carried: it counts the clean pages of the memory-mapped
canonical audio, which is exactly what `phys_footprint` was chosen to exclude,
so the bounded-memory assertion is weaker on both. **That Windows branch has
never been compiled** and is marked as such in the source; it is the first
thing to check on the first Windows build.

`AtomicFile.fsyncDirectory` called `open(2)` on a directory, which Windows
cannot do at all — a directory has no file handle there and NTFS has no
equivalent flush. The durable rename Windows offers is `MoveFileEx` with
`MOVEFILE_WRITE_THROUGH`, a property of the move rather than a separate flush,
and `FileManager` does not expose it. So the call is now guarded and the gap is
documented where it happens: on Windows the *data* is still flushed, so a power
loss can cost a project its newest artifact but cannot leave a half-written
one.

The near-miss is worth recording. The obvious guard was
`#if canImport(Darwin) || canImport(Glibc)`. A probe build proved the static
Linux SDK provides **`Musl`, not `Glibc`** — so that spelling would have
silently disabled directory flushing on the very Linux build this project
targets, with no error and no failing test. The guard includes `Musl`.

### Step 2, done: the C ABI

`Sources/VoxScriptaFFI` exports twelve C symbols; `ffi/voxscripta.h` is the
header Dart's ffigen reads. Five decisions shape it, each argued in the source:
polling rather than callbacks (a C function pointer called from a Swift
executor thread reaches Dart on a thread Dart does not own, which is the
standard way to crash a Flutter app); scalar getters rather than a shared
struct; nothing that blocks; every buffer released by the library's own
`vs_string_free` / `vs_bytes_free`, never `free()`, because a Windows DLL and
its host can hold separate C runtime heaps; and a per-thread last error, so two
Dart isolates cannot read each other's failures.

Verified four ways, not one:

| | |
| --- | --- |
| `VoxScriptaFFITests` | 10 tests — handle lifecycle, unknown handles, ownership, all five export formats |
| `dlopen` from Python | loaded the dylib and drove a real job to failure from outside Swift entirely |
| A C client | compiled against the header, linked against the library, ran |
| `Tools/check-abi.sh` | references all twelve symbols, so the link fails if the hand-written header drifts |

It also cross-compiles for `aarch64-linux-musl`.

The last error being per *OS thread* and not per *task* is a real distinction
and is pinned by a test. A `Task.detached` was the first thing tried as a stand-in
for a second isolate and it failed: Swift's cooperative pool ran it on the
spawning thread, so it read the same error back. An isolate is an OS thread,
which is the granularity this gives.

### What is still ahead for Windows

Steps 3 and 4 are untouched and neither can start here. The engine needs the
MSVC toolset and the Windows SDK, and the Flutter application needs Flutter
installed — and a Windows machine to produce a Windows binary from it.
