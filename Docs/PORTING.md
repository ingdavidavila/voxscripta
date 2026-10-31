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
| Audio decode | `AVFoundation` | miniaudio, **partly done** | `CanonicalDecoding` |
| Recording | `AVCaptureSession` | miniaudio, Oboe on Android | `RecordingSession` |

Two more, smaller:

- **Accelerate** in the DSP. The algorithms are already deterministic and
  tested against synthetic ground truth; plain Swift carries them, with SIMD
  only where a measurement says it is needed.
- **`NLEmbedding`**, used for the semantic-distance check in the polish
  gauntlet. It is already known to contribute nothing in Spanish — the
  corpus proved the lexical checks catch every polarity inversion on their
  own — so the honest fallback is to run without it and have the check
  abstain visibly, which it is already built to do.

## The container gap, which is a decision

`PortableDecoder` reads wav, flac and mp3, converts to 16 kHz mono on the way
out, and agrees with AVFoundation to within 0.0071 of full scale on the same
file — one sample of group delay apart.

What it cannot read is AAC: an `.m4a`, or the audio inside an `.mp4` or
`.mov`. That is not a rounding error in coverage. **The app records m4a**, so
as things stand a recording made on a Mac cannot be opened on Linux, and a
recording made on Android could not be opened at all if Android recorded the
same way. Imported video is a stated feature and would not work either.

Three ways to close it, and the choice is not technical:

1. **FFmpeg** — full parity, including video containers, and the only option
   that matches AVFoundation's matrix. LGPL 2.1, which is workable for a
   closed app when linked dynamically, and adds several megabytes.
2. **A system decoder per platform** — MediaFoundation, MediaCodec,
   GStreamer. No new licence, three more implementations to keep agreeing.
3. **Record WAV or FLAC off Apple and accept the import gap** — no new
   dependency, and the app can always open its own recordings. Someone handing
   it an m4a from a phone is still stuck.

Until this is decided, the portable decoder is honest about the limit: an
unreadable container is reported by name through `unsupportedContainer`,
which is the error the interface already explains.

## What this costs the user, stated plainly

Keeping Apple's recogniser on Apple means **the same recording can produce
different words on a phone than on a PC**. That is a real cost and it is not
hidden: `EngineID` is already written into every transcript's provenance, so
any two transcripts can be compared and the difference attributed.

The alternative — whisper.cpp everywhere — buys identical output at the price
of the Mac's measured 120× real-time speed and its current accuracy. That
trade was offered and declined.

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
