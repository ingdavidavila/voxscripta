# Building the Windows side

Demonstrated on Windows 11 with the Swift 6.4.2 toolchain: the engine builds
to `VoxScriptaFFI.dll`, the Dart engine package passes its tests against it, and
the Flutter app imports `jfk.wav` and shows its transcript. Not in CI; this is
the manual procedure, written so it can be repeated rather than remembered.

## What it does not cover

Recording with a real microphone (only silent input has been tried), the Open
and Save dialogs (PowerShell dialogs, never driven in a real desktop session),
signing and an installer.

Known gap: `ProjectStore.isAbsolutePath` does not accept UNC paths
(`\\server\share\audio.m4a`), so a project whose source sits on a network share
reports its audio as unavailable. Follow-up.

## Prerequisites

- Swift 6.4.2 for Windows from swift.org, with Visual Studio's Windows SDK.
- Flutter 3.47.x with the Windows desktop target.
- CMake and Ninja, plus the MSYS2 packages `make nasm pkgconf diffutils` and
  `mingw-w64-ucrt-x86_64-gcc`. MSYS2 is used only to run FFmpeg's `configure`.
- The submodules: `git submodule update --init --depth 1` (about 350 MB).
- A speech model in `build/models/`, for example `Tools/fetch-whisper-model.sh`.

## Build, in this order

All from Git Bash (or an MSYS2 shell) at the repository root.

```
# 1. FFmpeg, from an MSYS2 UCRT64 shell: shared DLLs plus import libraries
MSYSTEM=UCRT64 /c/msys64/usr/bin/bash.exe -lc "cd $PWD && Tools/build-ffmpeg.sh host"

# 2. llama.cpp, ggml and whisper.cpp as static libraries, built with the same
#    MSVC runtime the Swift side links against
CMAKE_GENERATOR=Ninja CC=clang-cl CXX=clang-cl Tools/build-engines.sh host

# 3. The engine
swift build --product VoxScriptaFFI --scratch-path build/win-swift

# 4. Gather the DLLs the app loads
Tools/stage-windows.sh

# 5. The app
cd flutter/app && flutter build windows --debug
```

`windows/CMakeLists.txt` copies `build/windows-engine/*.dll` beside
`voxscripta.exe` on every build and installs them with it, plus any
`build/models/ggml-*.bin` as `models/`, which is where `ModelSearch` looks.

After any `flutter` command, `git checkout -- flutter/app/linux flutter/app/macos
flutter/app/windows/flutter`: it regenerates plugin files there.

## The GPU engine (optional)

A second build of the engine runs transcription, and polish when a model is
present, on any GPU with a Vulkan driver: NVIDIA, AMD or Intel. It needs the
Vulkan SDK (headers, `glslc`, `vulkan-1.lib`).

```bash
VOXSCRIPTA_VULKAN=1 CMAKE_GENERATOR=Ninja CC=clang-cl CXX=clang-cl Tools/build-engines.sh host
VOXSCRIPTA_VULKAN=1 swift build --product VoxScriptaFFI     --scratch-path build/win-swift-vulkan --cache-path build/win-swift-cache
Tools/stage-windows.sh
```

Without the SDK, name the pieces with `Vulkan_INCLUDE_DIR`, `Vulkan_LIBRARY`
and `Vulkan_GLSLC_EXECUTABLE`, and the folder holding `vulkan-1.lib` with
`VOXSCRIPTA_VULKAN_LIB_DIR`.

Staging puts it beside the CPU engine as `VoxScriptaFFI-vulkan.dll`. The app
tries it first. What happens on each machine:

| Machine | Runs |
|---|---|
| Vulkan and a usable GPU | the GPU engine, on the GPU |
| Vulkan but no usable GPU driver | the GPU engine, which falls back to its CPU code |
| no `vulkan-1.dll` | the GPU engine fails to load; the CPU engine is used |

Not covered: only an NVIDIA GTX 1660 has run it; running out of video memory
has not been tried; a driver that crashes takes the app with it, because the
choice is made once, at load. The GPU's text is not identical to the CPU's.

## Checking it

```
# the engine, against the DLL
cd flutter/voxscripta_engine
VOXSCRIPTA_LIBRARY=<repo>\build\windows-engine\VoxScriptaFFI.dll dart test

# the whole app, from import to transcript, with screenshots
cd flutter/app
VOXSCRIPTA_TEST_AUDIO=<jfk.wav> VOXSCRIPTA_WHISPER_MODEL=<ggml-base.bin> \
VOXSCRIPTA_SHOT_DIR=<folder> flutter test integration_test/desktop_job_test.dart -d windows
```

Screenshots come from the app's own render tree: a window grab of a GPU-drawn
Flutter window is blank, and a session without an interactive desktop cannot
take one at all.

## What the first Windows build needed, in `Sources/`

Each behind a Windows condition: `K32GetProcessMemoryInfo` (Bench),
`TerminateProcess` for the simulated crash (JobRunner), no `c++` link and the
library search paths (Package.swift), and a drive-letter-aware absolute-path
check in `ProjectStore.resolveSource`. The last was a real bug: off Apple
platforms a project's source is its stored path, and requiring a leading `/`
failed every Windows job as "could not be found".
