# Running the Android side

Everything here was written on a Mac with no JDK, no Android SDK and no device.
That gap is now closed.

## It runs, 2026-11-04

**12 of 12 checks green, on an Android 15 x86_64 emulator.** The first time
anything in this project has executed on Android. Done from the Windows
machine with NDK 27.0.12077973, CMake 3.22.1 and platform 36, installed
through the command-line tools. `Tools/verify-android-core.sh` passes all four
ABIs and all five JNI symbols.

What that proves, in the order it matters: `int64` survives the JNI boundary
intact — six hours at 48 kHz is 1,036,800,000 samples and it came back exact;
the exception translation works, so a C++ throw arrives in Kotlin as an
`ArithmeticException` rather than calling `std::terminate` and killing a
six-hour job with no stack; and a compound value round-trips, not just
scalars.

The rest of this document is the original instructions, kept because the next
person to set up a machine needs them.

## First run

1. Pull the branch, then in Android Studio: **File → Open** and select the
   `android` directory — not the repository root. The root is a Swift package
   and Studio will make nothing of it.

2. Studio will report no Gradle wrapper. Let it create one, or run
   `gradle wrapper` once if you have Gradle on the path. The wrapper is not
   committed because its `.jar` cannot be generated without a JDK.

3. **SDK Manager → SDK Tools**: make sure **NDK (Side by side)** and **CMake**
   are installed. Gradle needs both; `Tools/verify-android-core.sh` will find
   whichever versions you have.

4. Run the `app` configuration on an emulator or a device.

Expected result: a plain screen listing twelve checks, all green.

The count was written as thirteen here before anything had been run, and the
harness has twelve: four `format` cases, four sample and nanosecond
conversions, one padded-range round trip, and three that assert a throw.
Corrected against the source rather than against memory.

## What that screen actually proves

`CoreCheckActivity` is a harness rather than a product screen, and it is
deleted once the React Native shell exists. Its expected values are copied from
`Tests/VoxScriptaCoreTests`, which is the specification during the migration.
A red row means the C++ port has drifted from the implementation the macOS app
ships, and the parity suite on the Mac should have caught it.

Three of the checks matter more than the others:

- **6 h at 48 kHz → 1,036,800,000 samples.** On a 32-bit ABI this is the value
  that breaks if `int64` does not survive the JNI boundary intact.
- **Overflow becomes `ArithmeticException`.** The core throws where the Swift
  code traps. An exception escaping a JNI frame calls `std::terminate`, and a
  six-hour job dying with no stack and no message is the worst failure this app
  has. This row is the proof that the translation works.
- **Padded range round-trips.** A compound value crossing the boundary, not
  just scalars.

If the app crashes instead of showing red rows, the exception translation in
`android/jni/voxscripta_jni.cpp` is wrong. That is the single most important
thing to get right before any more of the core is bridged.

## Likely first-run friction

I could not compile any of this, so expect to fix one or two of these:

- **Plugin versions.** `android/build.gradle.kts` pins AGP 8.13.0 and Kotlin
  2.2.20. If your Studio is older or newer it will offer an upgrade or refuse
  the version; take its suggestion.
- **`compileSdk = 36`.** If that platform is not installed, SDK Manager will
  offer it, or drop to the newest you have.
- **CMake version.** The module asks for `3.22.1+`. The SDK-bundled CMake
  satisfies this.

None of these touch the native code, which is known to build.

## A fresh clone needs the submodules first

`vendor/` holds four git submodules — whisper.cpp, llama.cpp, miniaudio and
FFmpeg — so a fresh clone has four empty directories and the build fails at
`'llama.h' file not found` in `Sources/CLlama/include/CLlama.h`. Before any
`swift build` on a new machine:

    git submodule update --init --recursive

The pins are deliberate and worth not drifting from: FFmpeg n7.1.1,
llama.cpp b12017, miniaudio 0.11.25, whisper.cpp master at 482279b.

## Verifying without Studio

Runs on macOS, Linux and Windows (Git Bash or WSL). It finds the SDK from
`ANDROID_HOME`, `ANDROID_SDK_ROOT`, or each platform's default location, so no
configuration is normally needed:

```bash
./Tools/verify-android-core.sh
```

It builds all four ABIs and asserts that every `external fun` in `NativeTime.kt`
has a matching exported symbol. A drifted JNI symbol is an
`UnsatisfiedLinkError` at the first call rather than a build error, which is why
it is checked by name instead of assumed.

The core's own tests run on the host:

```bash
cmake -S core -B build/core && cmake --build build/core
./build/core/tests/voxscripta_core_tests
```

## What is deliberately absent

No `INTERNET` permission, and no permissions at all, in
`app/src/main/AndroidManifest.xml`. That is the Android counterpart of the macOS
build's missing network entitlement: §26 is enforced by the platform rather than
by our restraint. `Tools/make-app-bundle.sh` fails the macOS build if a network
entitlement appears; the Android build should grow the same check before any
release.

32-bit ABIs are built on purpose even though no modern phone needs them. They
exercise `int64` arithmetic and `__builtin_mul_overflow` on targets the 64-bit
builds do not, and the core's overflow guard was first exercised there.

## Where this sits in the plan

This is the tail of the spike, not the start of the app. The architecture and
the phase order are in the plan; the short version is that the engine port
(P1–P2) needs no Android at all and is verified on the Mac against the Swift
original, while the Android work proper — MediaCodec decoding, whisper.cpp over
JNI, a foreground service for long jobs, SAF for durable file access — is P4 and
depends on P1 through P3 landing first.

The one number still missing is whisper.cpp's real-time factor on real hardware.
Every Android performance figure quoted so far is an estimate.
