import 'package:flutter/material.dart';

import 'package:voxscripta_engine/voxscripta_engine.dart';

import 'src/auth/account_section.dart';
import 'src/auth/auth_backend.dart';
import 'src/auth/auth_gate.dart';
import 'src/auth/auth_service.dart';
import 'src/engine_host.dart';
import 'src/library/library_model.dart';
import 'src/library/library_screen.dart';
import 'src/platform_traits.dart';
import 'src/import/import_sheet.dart';
import 'src/paywall/entitlement_model.dart';
import 'src/paywall/paywall_screen.dart';
import 'src/paywall/subscription_service.dart';
import 'src/paywall/trial_banner.dart';
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

  /// Null until an account service is chosen; see `auth_backend.dart`. When it
  /// is null the gate does not appear and Settings shows no account rows,
  /// because there is genuinely nothing to sign in to.
  final AuthService? _auth = configuredAuthService();

  /// Null until a store is wired; see `paywall/subscription_service.dart`.
  /// The engine enforces the wall either way, which is why that file says so
  /// at length.
  final SubscriptionService? _store = configuredSubscriptionService();

  /// The trial, read from the engine. Built once the engine is open.
  EntitlementModel? _entitlement;

  @override
  void initState() {
    super.initState();
    _host.addListener(_onHostChanged);
    _host.open();
  }

  /// Starts watching the trial as soon as there is an engine to ask.
  void _onHostChanged() {
    final engine = _host.engine;
    if (_entitlement == null && engine != null) {
      final model = EntitlementModel(engine)
        ..addListener(() => setState(() {}));
      _entitlement = model;
      model.start();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _entitlement?.dispose();
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
      home: AuthGate(auth: _auth, builder: (context, _) => _home()),
    );
  }

  /// The trial strip above the library, or nothing while the answer is
  /// unknown or the user is subscribed.
  Widget? _trialBanner() {
    if (_entitlement?.entitlement case final entitlement?) {
      return TrialBanner(
        entitlement: entitlement,
        onSubscribe: _showPaywall,
      );
    }
    return null;
  }

  /// Shows the paywall if new work is blocked. Returns true when it did, which
  /// means the caller should stop.
  bool _walled(BuildContext context) {
    final model = _entitlement;
    if (model == null || model.allowsNewWork) return false;
    _showPaywall(context);
    return true;
  }

  void _showPaywall(BuildContext context) {
    final entitlement = _entitlement?.entitlement;
    if (entitlement == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PaywallScreen(
          entitlement: entitlement,
          service: _store,
          // The engine is the authority, so a purchase is believed only once
          // the engine has been told and asked again.
          onSubscribed: (context) {
            _entitlement?.refresh();
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  /// The account rows for Settings, or nothing when no account service is
  /// configured.
  Widget? _accountSection() {
    if (_auth case final auth?) return AccountSection(auth: auth);
    return null;
  }

  Widget _home() {
    if (_host.engine case final engine?) {
      return LibraryScreen(
        model: LibraryModel.of(engine),
        banner: _trialBanner(),
        openImporter: (context) async {
          // The wall, before the file dialog. The engine refuses anyway, but
          // asking someone to choose a file and then telling them no is a
          // worse way to say the same thing.
          if (_walled(context)) return;
          final choice = await ImportSheet.show(context);
          if (choice == null || !context.mounted) return;
          _startJob(
            context,
            engine,
            audioPath: choice.audioPath,
            displayName: _fileName(choice.audioPath),
          );
        },
        openRecorder: (context) => _walled(context)
            ? null
            : Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RecordingScreen(
              model: RecordingModel.of(engine),
              // Straight into the pipeline, which is the point of recording in
              // the app: the file is handed to exactly the import path a
              // chosen file takes.
              onFinished: (context, result) => _startJob(
                context,
                engine,
                audioPath: result.path,
                displayName: _fileName(result.path),
                replace: true,
              ),
            ),
          ),
        ),
        openSettings: (context) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsScreen(
              model: SettingsModel.of(engine),
              accountSection: _accountSection(),
            ),
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

/// Creates a project for [audioPath] and shows it running.
///
/// One path for both ways audio arrives — a file the user chose and one they
/// just recorded — which is the point: nothing downstream knows the
/// difference, and neither does this.
void _startJob(
  BuildContext context,
  VoxScriptaEngine engine, {
  required String audioPath,
  required String displayName,
  bool replace = false,
}) {
  final route = MaterialPageRoute<void>(
    builder: (_) => ProcessingScreen(
      model: ProcessingModel.of(
        engine,
        projectPath: _projectPathFor(engine, audioPath),
        audioPath: audioPath,
        displayName: displayName,
        options: SettingsModel.of(engine).toJobOptions(),
      ),
      onFinished: (context, _) => Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => TranscriptScreen(
            model: TranscriptModel.of(
              engine,
              projectPath: _projectPathFor(engine, audioPath),
              displayName: displayName,
            ),
          ),
        ),
      ),
    ),
  );
  if (replace) {
    Navigator.of(context).pushReplacement(route);
  } else {
    Navigator.of(context).push(route);
  }
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
