import 'package:flutter/material.dart';

import 'src/engine_host.dart';
import 'src/library/library_model.dart';
import 'src/library/library_screen.dart';
import 'src/platform_traits.dart';
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
        openProject: (context, project) => Navigator.of(context).push(
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
