# Windows platform layer

Everything that needs the Windows SDK. `core/` stays platform-neutral; this
directory attaches Windows services to it.

| Piece | Status |
|---|---|
| Media Foundation decoder (`mf_decoder`) | done — WAV, AAC/M4A/MP4, MP3, WMA, FLAC where Windows has the codec |
| whisper.cpp transcription engine | next |
| Merger, exporters, CLI | next |
| UI | later |

AIFF, CAF and Ogg have no Media Foundation demuxer; they fail with
`UnsupportedFormat` so the caller can ask for a conversion.

## Build and test

MSYS2 UCRT64 g++, CMake and Ninja on `PATH`:

```
cmake -S windows -B build/windows -G Ninja
cmake --build build/windows
./build/windows/voxscripta_windows_tests.exe
```

The core's own tests build separately from `core/`.
