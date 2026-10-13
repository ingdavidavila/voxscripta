# Windows platform layer

Everything that needs the Windows SDK. `core/` stays platform-neutral; this
directory attaches Windows services to it.

| Piece | Status |
|---|---|
| Media Foundation decoder (`mf_decoder`) | done: WAV, AAC/M4A/MP4, MP3, WMA, FLAC where Windows has the codec |
| whisper.cpp engine (`../whisper`) | done: `small` model, CPU only |
| Scheduler, merger, txt/md/srt/vtt export (`../core`) | done |
| `voxscripta-cli` | done |
| `.docx` export, clean/polished transcripts | not ported yet |
| Resume after a crash | not ported yet (the job store is Swift-only) |
| UI | later |

AIFF, CAF and Ogg have no Media Foundation demuxer; they fail with
`UnsupportedFormat` so the caller can ask for a conversion.

## First-time setup

MSYS2 UCRT64 g++, CMake and Ninja on `PATH`, then:

```
bash Tools/fetch-whisper.sh                  # whisper.cpp v1.9.5 and ggml-small.bin (~465 MB)
cmake -S windows -B build/windows -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/windows
```

## Using it

```
build\windows\voxscripta-cli.exe transcribe talk.mp3 --format txt,srt,vtt,md -o out
build\windows\voxscripta-cli.exe analyze talk.mp3     # silence map and chunk plan, no model
build\windows\voxscripta-cli.exe help
```

Ctrl+C cancels cleanly. Exit codes: 0 ok, 2 no speech found, 3 some chunks failed
(gap markers are left in the transcript), 64 bad arguments, 65 unreadable audio,
66 file not found.

## Tests

```
build\windows\voxscripta_windows_tests.exe     # decoder, Whisper engine
build\core\tests\voxscripta_core_tests.exe     # after: cmake -S core -B build/core -G Ninja
```

The Whisper tests transcribe real speech from Windows' own voice. Generate it once with
`powershell -File Tools/make-speech-fixture.ps1`; without it those tests report
"skipped" rather than passing.
