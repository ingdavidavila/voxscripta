import 'dart:io';

import 'package:voxscripta_engine/voxscripta_engine.dart';

/// Records three seconds and reports what came out.
///
/// A diagnostic rather than a test: opening a microphone cannot be done in a
/// suite without prompting a developer and failing a build server. This is the
/// only way the capture path gets exercised at all, so it exists to be run by
/// hand on each platform as that platform becomes buildable.
void main(List<String> args) async {
  final engine = VoxScriptaEngine.open(libraryPath: args[0]);
  print('recordings go to: ${engine.recordingDirectory}');
  print('next path:        ${engine.newRecordingPath()}');

  final Recording recording;
  try {
    recording = engine.startRecording();
  } on VoxScriptaException catch (failure) {
    print('\ncould not open the microphone: ${failure.message}');
    exit(1);
  }

  print('\nrecording for three seconds…');
  var peak = 0.0;
  recording.progress.listen((report) {
    if (report.level > peak) peak = report.level;
  });

  await Future<void>.delayed(const Duration(seconds: 3));
  final result = recording.finish();

  print('state after finish: ${recording.latest.state.name}');
  print('peak level:         ${peak.toStringAsFixed(3)}');
  if (result == null) {
    print('no result reported');
    exit(1);
  }
  final file = File(result.path);
  print('wrote:              ${result.path}');
  print('duration:           ${result.duration.inMilliseconds} ms');
  print('exists:             ${file.existsSync()}');
  print('bytes:              ${file.existsSync() ? file.lengthSync() : 0}');
  // Left on disk deliberately: a check that deleted its own evidence would be
  // one you had to trust.
}
