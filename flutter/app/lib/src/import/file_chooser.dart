import 'dart:io';

/// Choosing an audio file, without a plugin.
///
/// A file-picker plugin would be the obvious answer and is the right one
/// eventually — it is the only way to reach Android's document provider. It is
/// not the answer today, for a reason worth writing down: a plugin needs
/// CocoaPods on macOS, macOS is the only platform this app can currently be
/// run on, and no CocoaPods is installed. Adding one would have traded a
/// working feature for an unverifiable one.
///
/// So this asks the desktop for its own dialog — `osascript` on a Mac,
/// `zenity` or `kdialog` on Linux, PowerShell on Windows — which is how
/// console tools have always done it. Where none is available the interface
/// falls back to a typed path, which is why [isAvailable] exists: the feature
/// is never a dead end, it just gets less pleasant.
///
/// Android is not covered and cannot be: there is no shell dialog there. That
/// is the point at which the plugin has to arrive, and by then CocoaPods will
/// be a smaller problem than shipping an Android app that cannot open a file.
class FileChooser {
  const FileChooser();

  /// Extensions the pipeline can decode. The same list the SwiftUI open panel
  /// offers, so neither interface accepts a file the other would refuse.
  static const List<String> audioExtensions = [
    'm4a', 'mp4', 'mov', 'wav', 'mp3', 'flac', 'aiff', 'aif',
    'ogg', 'opus', 'caf', 'aac', 'mka', 'au',
  ];

  /// Whether a native dialog can be shown here.
  bool get isAvailable =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Shows the platform's own open panel and returns the chosen path.
  ///
  /// Null when the user cancelled, or when no dialog could be shown.
  Future<String?> choose() async {
    if (Platform.isMacOS) return _run('osascript', ['-e', _appleScript()]);
    if (Platform.isLinux) return _linux();
    if (Platform.isWindows) {
      return _run('powershell', ['-NoProfile', '-Command', _powerShell()]);
    }
    return null;
  }

  Future<String?> _linux() async {
    // zenity on GNOME, kdialog on KDE. Neither is guaranteed on a minimal
    // install, which is exactly why the typed path exists.
    final zenity = await _run('zenity', [
      '--file-selection',
      '--title=Choose audio',
      '--file-filter=Audio | ${audioExtensions.map((e) => '*.$e').join(' ')}',
    ]);
    if (zenity != null) return zenity;
    return _run('kdialog', ['--getopenfilename', '.', _kdialogFilter()]);
  }

  Future<String?> _run(String command, List<String> arguments) async {
    try {
      final result = await Process.run(command, arguments);
      // A cancelled dialog exits non-zero on every platform here, which is
      // not a failure — it is an answer.
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    } on ProcessException {
      // The tool is not installed. The caller falls back to a typed path.
      return null;
    }
  }

  String _appleScript() {
    final types = audioExtensions.map((e) => '"$e"').join(', ');
    return 'POSIX path of (choose file with prompt "Choose audio" '
        'of type {$types})';
  }

  String _kdialogFilter() =>
      'Audio (${audioExtensions.map((e) => '*.$e').join(' ')})';

  String _powerShell() => '''
Add-Type -AssemblyName System.Windows.Forms
\$d = New-Object System.Windows.Forms.OpenFileDialog
\$d.Filter = "Audio|${audioExtensions.map((e) => '*.$e').join(';')}"
if (\$d.ShowDialog() -eq "OK") { Write-Output \$d.FileName } else { exit 1 }
''';
}
