# voxscripta_engine

Dart bindings for the Vox Scripta engine's C ABI. This is what the Flutter
interface — Android, Windows and Linux — talks to.

It contains **no rules**: not one threshold, not one piece of transcript
formatting, no decision about which model runs. Everything is a call into the
engine. That is deliberate and it is the only thing stopping the two interfaces
from drifting apart, since a rule that lived here would be a rule the SwiftUI
app could not see.

## Using it

```dart
final engine = VoxScriptaEngine.open();           // throws on an ABI mismatch

final job = engine.startJob(
  audioPath: '/path/to/interview.m4a',
  projectPath: '/path/to/interview.voxscripta',
);

await for (final report in job.progress) {
  print('${report.state.name} ${(report.fraction * 100).round()}%  ${report.detail}');
}

final outcome = await job.done;
if (outcome.state == JobState.complete) {
  final text = await engine.export(
    projectPath: '/path/to/interview.voxscripta',
    variant: TranscriptVariant.clean,
    format: ExportFormat.plainText,
  );
}
job.dispose();
```

In Flutter, pair `latest` with the stream, because a broadcast stream does not
replay to a late subscriber:

```dart
StreamBuilder<JobProgress>(
  initialData: job.latest,
  stream: job.progress,
  builder: (context, snapshot) => Text(snapshot.data!.detail),
)
```

## What the layers are for

| | |
| --- | --- |
| `src/bindings.dart` | The twelve symbols, and the only file that touches a `Pointer`. Ownership mistakes can only be made here, where they are easy to look for. |
| `src/model.dart` | States, variants, formats. Codes map through an explicit switch so a case added to the engine cannot renumber what a shipped build understands. |
| `src/job.dart` | Turns the ABI's poll into a `Stream`. Suppresses ticks that say nothing new, and closes itself at a terminal state so `await for` ends on its own. |
| `src/engine.dart` | Opening the library, starting jobs, exporting. |

Two things are worth knowing before changing any of it.

**Polling starts when a `Job` is constructed, not when something subscribes.**
The job is already running inside the engine, and `done` has to complete whether
or not a screen is watching. The first version started the timer in `onListen`,
which made `await job.done` hang forever unless you also listened to `progress`.

**`export` runs on a helper isolate.** It is the one call that really does work
before returning — it reads a transcript and renders it, and `docx` builds a
ZIP. The library is re-opened inside that isolate rather than captured, because
a `DynamicLibrary` cannot cross an isolate boundary but a path can, and opening
it again only bumps a reference count.

## Testing

```
Tools/test-dart.sh
```

Builds the engine first, then runs the bindings against the real
`libVoxScriptaFFI` — there is no mock, because the thing under test *is* the
boundary. The tests skip rather than fail when the engine has not been built, so
a fresh checkout is not a red suite.

Three checks guard this boundary, each catching something the others cannot:

| | |
| --- | --- |
| `Tools/check-abi.sh` | the hand-written C header still matches the Swift library |
| `VoxScriptaFFITests` | the ABI behaves — handles, ownership, every export format |
| `Tools/test-dart.sh` | these bindings still resolve and drive it |
