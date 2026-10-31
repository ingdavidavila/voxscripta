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
