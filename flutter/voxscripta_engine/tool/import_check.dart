import 'dart:convert';
import 'dart:io';

import 'package:voxscripta_engine/voxscripta_engine.dart';

/// Imports a file and transcribes it, the way the app's import flow does.
///
/// The screens are covered by widget tests and the ABI by its own suite; what
/// neither proves is that the two meet — that a path chosen in a dialog
/// becomes a project, a running job and a transcript. This walks that path
/// once against a real file.
void main(List<String> args) async {
  final engine = VoxScriptaEngine.open(libraryPath: args[0]);
  final audio = args[1];
  final name = audio.split('/').last;
  final stem = name.contains('.') ? name.split('.').first : name;
  final project = '${engine.defaultLibraryDirectory}/$stem-import-check.voxscripta';

  print('audio:   $audio');
  print('project: $project\n');

  final job = engine.startJob(audioPath: audio, projectPath: project);
  var lastState = '';
  await for (final report in job.progress) {
    if (report.state.name != lastState) {
      lastState = report.state.name;
      print('  ${report.state.name.padRight(18)} '
          '${(report.fraction * 100).round().toString().padLeft(3)}%  '
          '${report.detail}');
    }
  }

  final outcome = await job.done;
  print('\nfinished: ${outcome.state.name}');
  if (outcome.failure case final reason?) {
    print('reason:   $reason');
    job.dispose();
    exit(1);
  }

  final summary = engine.summary(project);
  print('variants: ${summary.variants.map((v) => '${v.variant.wireName}'
      '(${v.words}w)').join(' ')}');
  print('polish:   ran=${summary.polish.ran} '
      'accepted=${summary.polish.accepted} kept=${summary.polish.keptClean}');
  if (summary.polish.skipReason case final reason?) {
    print('          skipped: $reason');
  }

  final text = utf8.decode(await engine.export(
    projectPath: project,
    variant: summary.variants.last.variant,
    format: ExportFormat.plainText,
  ));
  print('\ntranscript (${text.length} chars):');
  print(text.length > 300 ? '${text.substring(0, 300)}…' : text);

  job.dispose();
}
