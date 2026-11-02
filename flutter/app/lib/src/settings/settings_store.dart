import 'dart:convert';
import 'dart:io';

/// Where the interface keeps the choices the user has made.
///
/// A JSON file rather than shared_preferences, for a reason that is practical
/// rather than principled: a plugin would need CocoaPods on macOS and a
/// platform channel on every target, to store a dozen scalars. `dart:io`
/// already works everywhere this app runs.
///
/// These are the interface's own state — which defaults a user prefers — and
/// are deliberately not shared with the SwiftUI app. Two applications on two
/// machines have no business reading each other's preferences. What they do
/// share is the *values*' meaning, which is why every default comes from
/// `vs_job_options_defaults` and never from a literal here.
class SettingsStore {
  SettingsStore({required this.directory});

  /// Beside the library, because that is the folder this application owns and
  /// the one a user already knows to look in.
  final String directory;

  File get _file => File('$directory/flutter-settings.json');

  Map<String, Object?> load() {
    try {
      final file = _file;
      if (!file.existsSync()) return {};
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map<String, Object?>) return decoded;
      return {};
    } on Object {
      // A corrupt settings file is not worth failing a launch over. The
      // engine's defaults are a complete and valid set, so losing a
      // preference costs the user one adjustment rather than the application.
      return {};
    }
  }

  /// Writes through a temporary file and a rename, so a crash mid-write
  /// leaves the previous settings rather than half of the new ones. The same
  /// discipline the engine uses for everything it writes.
  bool save(Map<String, Object?> values) {
    try {
      Directory(directory).createSync(recursive: true);
      final temporary = File('${_file.path}.tmp');
      temporary.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(values), flush: true);
      temporary.renameSync(_file.path);
      return true;
    } on Object {
      return false;
    }
  }
}
