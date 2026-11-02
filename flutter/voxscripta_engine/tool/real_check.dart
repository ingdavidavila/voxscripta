import 'dart:convert';
import 'package:voxscripta_engine/voxscripta_engine.dart';

void main(List<String> args) async {
  final engine = VoxScriptaEngine.open(libraryPath: args[0]);
  final projects = engine.library();
  print('library: ${projects.length} projects');

  var checked = 0;
  for (final project in projects) {
    final summary = engine.summary(project.path);
    if (summary.variants.isEmpty) continue;
    checked += 1;
    final variants = summary.variants
        .map((v) => '${v.variant.wireName}(${v.words}w/${v.segments}s)')
        .join(' ');
    print('\n${project.displayName}');
    print('  variants: $variants');
    print('  polish:   ran=${summary.polish.ran} '
        'accepted=${summary.polish.accepted} '
        'retried=${summary.polish.acceptedAfterRetry} '
        'kept=${summary.polish.keptClean} '
        'flagged=${summary.polish.flagged.length}');
    if (summary.polish.skipReason case final reason?) {
      print('  skipped:  $reason');
    }
    final text = utf8.decode(await engine.export(
      projectPath: project.path,
      variant: summary.variants.last.variant,
      format: ExportFormat.plainText,
    ));
    final preview = text.length > 90 ? '${text.substring(0, 90)}…' : text;
    print('  text:     ${preview.replaceAll('\n', ' ⏎ ')}');
    if (checked >= 3) break;
  }
  print('\nchecked $checked projects with output');
}
