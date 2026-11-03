import 'dart:convert';
import 'dart:io';

import 'package:voxscripta_engine/voxscripta_engine.dart';

/// Compares clean against polished on real projects.
///
/// Written to settle one question: the polished variant reports far fewer
/// words than the clean one, and it matters enormously whether that is the
/// text being shorter or the count being wrong.
void main(List<String> args) async {
  final engine = VoxScriptaEngine.open(libraryPath: args[0]);
  var checked = 0;

  for (final project in engine.library()) {
    final summary = engine.summary(project.path);
    final clean = summary.forVariant(TranscriptVariant.clean);
    final polished = summary.forVariant(TranscriptVariant.polished);
    if (clean == null || polished == null) continue;

    String text(TranscriptVariant v) => '';
    final cleanText = utf8.decode(await engine.export(
        projectPath: project.path,
        variant: TranscriptVariant.clean,
        format: ExportFormat.plainText));
    final polishedText = utf8.decode(await engine.export(
        projectPath: project.path,
        variant: TranscriptVariant.polished,
        format: ExportFormat.plainText));

    int actualWords(String s) =>
        s.split(RegExp(r'\s+')).where((w) => w.trim().isNotEmpty).length;

    print(project.displayName);
    print('  reported   clean ${clean.words}w   polished ${polished.words}w');
    print('  in the text  clean ${actualWords(cleanText)}w   '
        'polished ${actualWords(polishedText)}w');
    print('  characters   clean ${cleanText.length}   '
        'polished ${polishedText.length}');
    print('');
    text(TranscriptVariant.clean);

    checked += 1;
    if (checked >= 3) break;
  }
  print('compared $checked projects');
}
