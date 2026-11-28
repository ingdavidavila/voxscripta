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

/// Which desktop's dialog to ask for.
///
/// Injectable for one reason: each of the three routes reaches the dialog
/// differently, and a test that reads the real [Platform] can only ever
/// exercise the route belonging to the machine it runs on. That is not a
/// hypothetical. The test asserting that the file name never lands in the
/// command passed on the Macs it was written on and failed on CI, which runs
/// Linux, because on Linux the name *is* an argument and is meant to be.
enum Desktop {
  macOS,
  windows,
  linux;

  static Desktop get current {
    if (Platform.isMacOS) return Desktop.macOS;
    if (Platform.isWindows) return Desktop.windows;
    return Desktop.linux;
  }
}

class DesktopFileSaver implements FileSaver {
  DesktopFileSaver({
    CommandRunner? runner,
    Directory? fallbackDirectory,
    Desktop? desktop,
  })  : _run = runner ?? _runCommand,
        _fallback = fallbackDirectory,
        _desktop = desktop ?? Desktop.current;

  final CommandRunner _run;
  final Directory? _fallback;
  final Desktop _desktop;

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
    if (_desktop == Desktop.macOS) {
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
    if (_desktop == Desktop.windows) {
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
      ['--getsavefilename', _notAnOption(name), '--title', title],
      env,
    );
    return (dialogShown: kdialog.ran, path: kdialog.stdout);
  }

  /// A name kdialog cannot mistake for one of its own options.
  ///
  /// zenity is handed `--filename=<name>`, where the value sits after the `=`
  /// and is safe whatever it starts with. kdialog takes the name as a bare
  /// positional argument, so a file called `-x.m4a` — which macOS and Linux
  /// both allow, and which arrives here as the imported audio's own name —
  /// would be read as an unknown option and the dialog would not open.
  /// `./-x.m4a` names the same file and cannot be read as a flag.
  static String _notAnOption(String name) =>
      name.startsWith('-') ? './$name' : name;

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
