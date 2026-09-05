# Hand-supplied fixtures

Almost every fixture in this project is synthesized at test time, which is why
the repository contains no binary audio: generation is deterministic, so a
committed file would add weight without adding certainty.

**MP3 is the exception.** macOS ships no MP3 encoder — `afconvert` refuses it in
every container and `AVAudioFile` has no format for it — so an MP3 fixture cannot
be generated the way the others are. §33 asks for MP3 coverage, and the honest
position is that MP3 *decoding* is untested until a real file is supplied here.

To cover it, drop any MP3 in this directory named:

```
Tests/Fixtures/sample.mp3
```

`DecoderTests.decodesSuppliedMP3` then runs the full decode path against it. With
no file present the test reports as **skipped**, not passed, so the gap stays
visible rather than looking like coverage.

Any speech recording works; a few seconds is enough. Nothing about the content
matters — the test asserts that decoding produces canonical audio of the right
length and non-trivial signal, not any particular transcript.
