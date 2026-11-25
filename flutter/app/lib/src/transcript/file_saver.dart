import 'dart:io';

import 'package:flutter/services.dart';

/// How a save ended.
sealed class SaveOutcome {
  const SaveOutcome();
}

/// The bytes are in a file. [where] is what to tell the person: a full path on
/// a desktop, the document's name on Android, where the system hides the path.
class Saved extends SaveOutcome {
  const Saved(this.where);
  final String where;
}

/// The person closed the dialog. An answer, not a failure, so nothing is shown.
class SaveCancelled extends SaveOutcome {
  const SaveCancelled();
}

/// The bytes could not be written, with the system's reason.
class SaveFailed extends SaveOutcome {
  const SaveFailed(this.reason);
  final String reason;
}

/// Writing a rendered transcript where the person chooses.
///
/// No plugin, for the reason the file chooser has none: what this app does with
/// the user's files has to be provable from our own code. Desktops use the
/// system's own save dialog through a command-line tool; Android asks its
/// document provider through a small channel (MainActivity.kt).
abstract interface class FileSaver {
  Future<SaveOutcome> save({
    required String suggestedName,
    required String mimeType,
    required Uint8List bytes,
    required String dialogTitle,
  });

  static FileSaver forPlatform() =>
      Platform.isAndroid ? const ChannelFileSaver() : DesktopFileSaver();
}

/// A name that is safe to put in a file dialog: no separators, no characters
/// Windows refuses, and never empty.
String safeFileName(String name, String extension) {
  var base = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  // The project's own name usually carries the audio's extension. A transcript
  // called "talk.m4a.txt" reads as a mistake.
  final dot = base.lastIndexOf('.');
  if (dot > 0 && base.length - dot <= 6) base = base.substring(0, dot);
  if (base.isEmpty) base = 'transcript';
  return '$base.$extension';
}

class ChannelFileSaver implements FileSaver {
  const ChannelFileSaver([this._channel = const MethodChannel(channelName)]);

  static const channelName = 'dev.voxscripta.voxscripta/save';

  final MethodChannel _channel;

  @override
  Future<SaveOutcome> save({
    required String suggestedName,
    required String mimeType,
    required Uint8List bytes,
    required String dialogTitle,
  }) async {
    try {
      final name = await _channel.invokeMethod<String>('save', {
        'name': suggestedName,
        'mime': mimeType,
        'bytes': bytes,
      });
      return name == null ? const SaveCancelled() : Saved(name);
    } on PlatformException catch (failure) {
      return SaveFailed(failure.message ?? failure.code);
    } on MissingPluginException {
      return const SaveFailed('this build has no way to save files');
    }
  }
}

/// Runs a command and says whether it ran. `null` stdout with `ran` true is a
/// cancelled dialog; `ran` false is a tool that is not installed.
typedef CommandRunner = Future<({bool ran, String? stdout})> Function(
    String command, List<String> arguments, Map<String, String> environment);

Future<({bool ran, String? stdout})> _runCommand(
  String command,
  List<String> arguments,
  Map<String, String> environment,
) async {
  try {
    final result = await Process.run(command, arguments,
        environment: environment, stdoutEncoding: systemEncoding);
    if (result.exitCode != 0) return (ran: true, stdout: null);
    final text = (result.stdout as String).trim();
    return (ran: true, stdout: text.isEmpty ? null : text);
  } on ProcessException {
    return (ran: false, stdout: null);
  }
}

class DesktopFileSaver implements FileSaver {
  DesktopFileSaver({CommandRunner? runner, Directory? fallbackDirectory})
      : _run = runner ?? _runCommand,
        _fallback = fallbackDirectory;

  final CommandRunner _run;
  final Directory? _fallback;

  @override
  Future<SaveOutcome> save({
    required String suggestedName,
    required String mimeType,
    required Uint8List bytes,
    required String dialogTitle,
  }) async {
    final choice = await _ask(suggestedName, dialogTitle);
    try {
      if (choice.dialogShown) {
        final path = choice.path;
        if (path == null) return const SaveCancelled();
        // The dialog has already asked about overwriting.
        await File(path).writeAsBytes(bytes, flush: true);
        return Saved(path);
      }
      // No dialog on this machine (a minimal Linux without zenity or kdialog).
      // Writing somewhere predictable and saying where beats a dead button, and
      // a name that is not taken beats overwriting a file nobody was asked about.
      final directory = _fallback ?? _defaultDirectory();
      await directory.create(recursive: true);
      final target = _unusedPath(directory, suggestedName);
      await File(target).writeAsBytes(bytes, flush: true);
      return Saved(target);
    } on FileSystemException catch (failure) {
      return SaveFailed(failure.osError?.message ?? failure.message);
    }
  }

  Future<({bool dialogShown, String? path})> _ask(
      String name, String title) async {
    final env = {'VS_NAME': name, 'VS_TITLE': title};
    if (Platform.isMacOS) {
      final r = await _run(
        'osascript',
        [
          '-e',
          'POSIX path of (choose file name with prompt (system attribute '
              '"VS_TITLE") default name (system attribute "VS_NAME"))',
        ],
        env,
      );
      return (dialogShown: r.ran, path: r.stdout);
    }
    if (Platform.isWindows) {
      final r = await _run(
        'powershell',
        ['-NoProfile', '-Command', _powerShell],
        env,
      );
      return (dialogShown: r.ran, path: r.stdout);
    }
    final zenity = await _run(
      'zenity',
      [
        '--file-selection',
        '--save',
        '--confirm-overwrite',
        '--title=$title',
        '--filename=$name',
      ],
      env,
    );
    if (zenity.ran) return (dialogShown: true, path: zenity.stdout);
    final kdialog = await _run(
      'kdialog',
      ['--getsavefilename', name, '--title', title],
      env,
    );
    return (dialogShown: kdialog.ran, path: kdialog.stdout);
  }

  // Name and title travel in the environment, never in the script text, so a
  // quote in a project's name cannot become code.
  static const _powerShell = r'''
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.SaveFileDialog
$d.FileName = $env:VS_NAME
$d.Title = $env:VS_TITLE
$d.OverwritePrompt = $true
if ($d.ShowDialog() -eq "OK") { Write-Output $d.FileName } else { exit 1 }
''';

  static Directory _defaultDirectory() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    final downloads = Directory('$home${Platform.pathSeparator}Downloads');
    return downloads.existsSync() ? downloads : Directory(home);
  }

  static String _unusedPath(Directory directory, String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var candidate = '${directory.path}${Platform.pathSeparator}$name';
    for (var n = 2; File(candidate).existsSync(); n++) {
      candidate = '${directory.path}${Platform.pathSeparator}$stem ($n)$ext';
    }
    return candidate;
  }
}

/// The media type the system's document picker and sharing sheets expect.
String mimeTypeFor(String extension) => switch (extension) {
      'txt' => 'text/plain',
      'md' => 'text/markdown',
      'docx' =>
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'srt' => 'application/x-subrip',
      'vtt' => 'text/vtt',
      _ => 'application/octet-stream',
    };
