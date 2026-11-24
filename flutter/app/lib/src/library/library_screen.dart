import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import '../l10n.dart';

import '../platform_traits.dart';
import 'library_model.dart';
import 'project_tile.dart';

/// The app's front door: everything already recorded or imported.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.model,
    this.openProject,
    this.openSettings,
    this.openRecorder,
    this.openImporter,
    this.banner,
  });

  final LibraryModel model;

  /// A strip above the list — the trial's state, when there is one to report.
  /// Supplied from outside so the library knows nothing about the paywall.
  final Widget? banner;

  /// Opens a project's transcript. Injected rather than built here so the
  /// library's tests do not need an engine to open a row.
  final FutureOr<void> Function(BuildContext, ProjectEntry)? openProject;

  /// Opens the settings screen. Injected for the same reason.
  final FutureOr<void> Function(BuildContext)? openSettings;

  /// Starts a new recording.
  final FutureOr<void> Function(BuildContext)? openRecorder;

  /// Opens an audio file that already exists.
  final FutureOr<void> Function(BuildContext)? openImporter;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onChanged);
    widget.model.refresh();
  }

  @override
  void dispose() {
    widget.model.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  /// Looks at the disk again once whatever was opened has been closed.
  ///
  /// An import, a recording or a finished job each add or change a project
  /// while this screen sits underneath, so without this the list stayed at
  /// "No recordings yet" until someone pressed refresh.
  void _returned(FutureOr<void> opened) {
    if (opened is Future<void>) {
      opened.whenComplete(() {
        if (mounted) widget.model.refresh();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;

    // Delete on the selection, which is what a desktop list does. There is no
    // key to press on a phone, so the row's own menu carries it there.
    return CallbackShortcuts(
      bindings: {
        if (PlatformTraits.hasPointer)
          const SingleActivator(LogicalKeyboardKey.delete): () {
            final project = model.selected;
            if (project != null) _confirmDelete(project);
          },
        const SingleActivator(LogicalKeyboardKey.f5): model.refresh,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(context.l10n.libraryTitle),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: context.l10n.libraryRefreshTooltip,
                onPressed: model.refresh,
              ),
              if (widget.openImporter case final open?)
                IconButton(
                  icon: const Icon(Icons.audio_file_outlined),
                  tooltip: context.l10n.libraryOpenTooltip,
                  onPressed: () => _returned(open(context)),
                ),
              if (widget.openRecorder case final record?)
                IconButton(
                  icon: const Icon(Icons.mic_none),
                  tooltip: context.l10n.libraryRecordTooltip,
                  onPressed: () => _returned(record(context)),
                ),
              if (widget.openSettings case final open?)
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: context.l10n.librarySettingsTooltip,
                  onPressed: () => open(context),
                ),
              const SizedBox(width: 4),
            ],
          ),
          body: widget.banner == null
              ? _body(model)
              : Column(
                  children: [
                    widget.banner!,
                    Expanded(child: _body(model)),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _body(LibraryModel model) {
    if (model.error case final message?) {
      return _Message(
        icon: Icons.error_outline,
        title: context.l10n.libraryUnreadableTitle,
        // The engine's own words. Paraphrasing them would lose the path, which
        // is usually the only part that makes this fixable.
        detail: message,
        action: FilledButton(onPressed: model.refresh, child: Text(context.l10n.tryAgain)),
      );
    }
    if (model.isLoading && model.projects.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (model.projects.isEmpty) {
      return _Message(
        icon: Icons.graphic_eq,
        title: context.l10n.libraryEmptyTitle,
        // Matches the SwiftUI empty state, plus the folder — "nothing here" is
        // much more useful when it says where "here" is.
        detail: context.l10n.libraryEmptyDetail(model.directory),
        // An empty list with nothing to tap is a dead end, which is why the
        // SwiftUI app shows the import screen instead of an empty sidebar on a
        // phone. Here the offer is the button.
        // Null rather than an empty Row when neither is wired, or the empty
        // state grows a blank band where the buttons would be.
        action: (widget.openRecorder == null && widget.openImporter == null)
            ? null
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.openRecorder case final record?)
                    FilledButton.icon(
                      onPressed: () => _returned(record(context)),
                      icon: const Icon(Icons.mic),
                      label: Text(context.l10n.record),
                    ),
                  if (widget.openRecorder != null && widget.openImporter != null)
                    const SizedBox(width: 12),
                  if (widget.openImporter case final open?)
                    OutlinedButton.icon(
                      onPressed: () => _returned(open(context)),
                      icon: const Icon(Icons.audio_file_outlined),
                      label: Text(context.l10n.openFile),
                    ),
                ],
              ),
      );
    }

    return ListView.builder(
      itemCount: model.projects.length,
      itemBuilder: (context, index) {
        final project = model.projects[index];
        return ProjectTile(
          project: project,
          isSelected: project.id == model.selectedId,
          onOpen: () {
            model.select(project.id);
            final open = widget.openProject;
            if (open == null) {
              _noTranscriptScreen(project);
            } else {
              _returned(open(context, project));
            }
          },
          onReveal: () => _reveal(project),
          onDelete: () => _confirmDelete(project),
        );
      },
    );
  }

  /// Only reached when no opener was supplied, which in the app it always is.
  /// Kept so a row never silently does nothing.
  void _noTranscriptScreen(ProjectEntry project) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(context.l10n.projectCannotOpen(project.displayName)),
    ));
  }

  Future<void> _reveal(ProjectEntry project) async {
    final shown = await PlatformTraits.revealInFileManager(project.path);
    if (!mounted || shown) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(context.l10n.couldNotOpenFileManager(PlatformTraits.fileManagerName)),
    ));
  }

  /// The delete flow, reachable by a test.
  ///
  /// Exposed because the gesture that opens the row menu is platform-dependent
  /// — right-click here, long-press there — while the confirmation is not, and
  /// the confirmation is the part that must never be skipped. A test that had
  /// to simulate the right gesture per platform would be testing the gesture.
  @visibleForTesting
  Future<void> confirmDeleteForTest(ProjectEntry project) => _confirmDelete(project);

  Future<void> _confirmDelete(ProjectEntry project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.deleteProjectTitle(project.displayName)),
        // The §5 promise, stated where the user is deciding rather than in a
        // document they will not read: the audio is not destroyed.
        content: Text(
          PlatformTraits.hasPointer && Theme.of(context).platform == TargetPlatform.macOS
              ? context.l10n.deleteExplainTrash
              : context.l10n.deleteExplainFolder,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final movedTo = widget.model.delete(project);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(movedTo == null
            ? context.l10n.deletedProject(project.displayName)
            : context.l10n.movedProjectTo(project.displayName, movedTo)),
      ));
    } on VoxScriptaException catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }
}

/// A centred icon, a line and an explanation. Used for both empty and broken,
/// because the difference between them is the words and not the layout.
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              SelectableText(
                detail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}
