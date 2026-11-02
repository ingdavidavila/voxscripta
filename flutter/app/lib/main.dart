import 'package:flutter/material.dart';

import 'package:voxscripta_engine/voxscripta_engine.dart';

import 'src/engine_host.dart';
import 'src/library/library_model.dart';
import 'src/library/library_screen.dart';
import 'src/platform_traits.dart';
import 'src/processing/processing_model.dart';
import 'src/processing/processing_screen.dart';
import 'src/recording/recording_model.dart';
import 'src/recording/recording_screen.dart';
import 'src/settings/settings_model.dart';
import 'src/settings/settings_screen.dart';
import 'src/transcript/transcript_model.dart';
import 'src/transcript/transcript_screen.dart';

void main() => runApp(const VoxScriptaApp());

/// Vox Scripta on Android, Windows and Linux.
///
/// The SwiftUI app serves Mac and iPhone; this serves the other three. The
/// contract between them is `Docs/PARITY.md`: the same features, each
/// platform's own conventions, and not one rule in either interface.
class VoxScriptaApp extends StatefulWidget {
  const VoxScriptaApp({super.key});

  @override
  State<VoxScriptaApp> createState() => _VoxScriptaAppState();
}

class _VoxScriptaAppState extends State<VoxScriptaApp> {
  final EngineHost _host = EngineHost();

  @override
  void initState() {
    super.initState();
    _host.addListener(() => setState(() {}));
    _host.open();
  }

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vox Scripta',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: _home(),
    );
  }

  Widget _home() {
    if (_host.engine case final engine?) {
      return LibraryScreen(
        model: LibraryModel.of(engine),
        openRecorder: (context) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RecordingScreen(
              model: RecordingModel.of(engine),
              // Straight into the pipeline, which is the point of recording in
              // the app: the file is handed to exactly the import path a
              // chosen file takes.
              onFinished: (context, result) =>
                  Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => ProcessingScreen(
                    model: ProcessingModel.of(
                      engine,
                      projectPath: _projectPathFor(engine, result.path),
                      audioPath: result.path,
                      displayName: _fileName(result.path),
                      options: SettingsModel.of(engine).toJobOptions(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        openSettings: (context) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsScreen(model: SettingsModel.of(engine)),
          ),
        ),
        openProject: (context, project) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => TranscriptScreen(
              model: TranscriptModel.of(
                engine,
                projectPath: project.path,
                displayName: project.displayName,
              ),
              // A project with no transcript can be run from where it is: the
              // package already references its audio, and the engine resumes
              // from whatever stage a previous attempt reached.
              onRun: (context) => Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                  builder: (_) => ProcessingScreen(
                    model: ProcessingModel.of(
                      engine,
                      projectPath: project.path,
                      displayName: project.displayName,
                      options: SettingsModel.of(engine).toJobOptions(),
                    ),
                    onFinished: (context, _) =>
                        Navigator.of(context).pushReplacement(
                      MaterialPageRoute<void>(
                        builder: (_) => TranscriptScreen(
                          model: TranscriptModel.of(
                            engine,
                            projectPath: project.path,
                            displayName: project.displayName,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return _EngineUnavailable(failure: _host.failure, onRetry: _host.open);
  }

  /// Material 3, with desktop density where there is a pointer.
  ///
  /// Density is the one theme choice that is a convention rather than a
  /// preference: desktop rows are tighter than touch rows because a mouse is
  /// more precise than a finger, and a touch-sized list on Windows looks as
  /// wrong as a desktop-sized one on a phone.
  ThemeData _theme(Brightness brightness) => ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B6EA5),
          brightness: brightness,
        ),
        visualDensity: PlatformTraits.hasPointer
            ? VisualDensity.compact
            : VisualDensity.standard,
        useMaterial3: true,
      );
}

/// Where a recording's project package goes: beside the library, named after
/// the audio. The engine owns the library's location; the package name is just
/// the file's.
String _projectPathFor(VoxScriptaEngine engine, String audioPath) {
  final name = _fileName(audioPath);
  final stem = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
  return '${engine.defaultLibraryDirectory}/$stem.voxscripta';
}

String _fileName(String path) =>
    path.contains('/') ? path.substring(path.lastIndexOf('/') + 1) : path;

/// Shown when the engine will not load.
///
/// Its own screen rather than a toast, because nothing in the application
/// works without the engine and an empty library would be a lie — it would
/// look exactly like having no recordings.
class _EngineUnavailable extends StatelessWidget {
  const _EngineUnavailable({required this.failure, required this.onRetry});

  final String? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.extension_off_outlined,
                    size: 48, color: theme.colorScheme.error),
                const SizedBox(height: 16),
                Text('The engine could not be loaded',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                SelectableText(
                  failure ?? 'No reason was reported.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: onRetry, child: const Text('Try again')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
