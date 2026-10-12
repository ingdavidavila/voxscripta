# Running the Android side

Everything here was written on a Mac with no JDK, no Android SDK and no device.
The native core is verified — it cross-compiles for all four ABIs and its
symbols bind — but **no Kotlin in this repository has ever been compiled, and
nothing has ever executed on Android.** That is the gap this document exists to
close, and the first thing you do on the Studio machine closes it.

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

Expected result: a plain screen listing thirteen checks, all green, headed
*"libvoxscripta runs — 13 checks, all matching Swift"*.

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

## Verifying without Studio

The cross-compile and the JNI contract can be checked from a terminal on either
machine:

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
