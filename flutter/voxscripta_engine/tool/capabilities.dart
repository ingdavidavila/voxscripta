import 'package:voxscripta_engine/voxscripta_engine.dart';

/// Prints what this machine can actually do, straight from the engine.
///
/// A diagnostic, not a test: the settings screen is built on these answers and
/// seeing them for the machine in front of you is how you tell whether the
/// screen is describing reality or a fixture.
void main(List<String> args) {
  final engine = VoxScriptaEngine.open(libraryPath: args[0]);
  final capabilities = engine.capabilities();

  final polish = capabilities.polish;
  print('polish');
  print('  apple intelligence: ${polish.systemModelAvailable}');
  print('  bundled model:      ${polish.bundledModel ?? "none"}');
  print('  will use:           ${polish.effective ?? polish.unavailableReason}');

  print('\nlocales: ${capabilities.locales.length}');
  final text = capabilities.locales.where((l) => l.hasTextSupport).length;
  final polished = capabilities.locales.where((l) => l.polishValidated).length;
  print('  with clean/polish support: $text');
  print('  polish validated:          $polished');
  for (final locale in capabilities.locales.take(6)) {
    print('  ${locale.identifier.padRight(8)} ${locale.displayName.padRight(28)}'
        ' text=${locale.hasTextSupport} polish=${locale.polishValidated}');
  }
}
