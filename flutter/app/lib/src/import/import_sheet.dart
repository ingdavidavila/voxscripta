import 'dart:io';

import 'package:flutter/material.dart';

import 'file_chooser.dart';

/// What the user has chosen to import.
class ImportChoice {
  const ImportChoice({required this.audioPath});

  final String audioPath;
}

/// Asks for an audio file.
///
/// Two ways in, because the dialog is not guaranteed: the platform's own open
/// panel where one exists, and a typed path always. The second is not a
/// consolation — it is how this works at all on a machine with no desktop
/// dialog installed, and it is the only route a test can take.
class ImportSheet extends StatefulWidget {
  const ImportSheet({super.key, this.chooser = const FileChooser()});

  final FileChooser chooser;

  /// Returns the chosen file, or null if the user backed out.
  static Future<ImportChoice?> show(
    BuildContext context, {
    FileChooser chooser = const FileChooser(),
  }) =>
      showDialog<ImportChoice>(
        context: context,
        builder: (_) => ImportSheet(chooser: chooser),
      );

  @override
  State<ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<ImportSheet> {
  final TextEditingController _path = TextEditingController();
  String? _error;
  bool _choosing = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Open audio'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.chooser.isAvailable) ...[
              OutlinedButton.icon(
                onPressed: _choosing ? null : _browse,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose a file…'),
              ),
              const SizedBox(height: 16),
              Text('or type a path',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 8),
            ],
            TextField(
              controller: _path,
              autofocus: !widget.chooser.isAvailable,
              decoration: const InputDecoration(
                hintText: '/path/to/interview.m4a',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _accept(),
            ),
            if (_error case final message?) ...[
              const SizedBox(height: 8),
              Text(message,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            Text(
              // §5, stated where the decision is made. The project references
              // the file; it does not move or change it.
              'The file stays where it is. Vox Scripta reads it and never '
              'modifies it.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _accept, child: const Text('Open')),
      ],
    );
  }

  Future<void> _browse() async {
    setState(() => _choosing = true);
    final chosen = await widget.chooser.choose();
    if (!mounted) return;
    setState(() {
      _choosing = false;
      if (chosen != null) _path.text = chosen;
    });
    if (chosen != null) _accept();
  }

  void _accept() {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _error = 'Choose a file, or type its path.');
      return;
    }
    // Checked here rather than left to the engine, because the engine's
    // refusal arrives asynchronously on a job that has already been created —
    // and a project for a file that is not there is litter.
    if (!File(path).existsSync()) {
      setState(() => _error = 'There is no file at that path.');
      return;
    }
    final extension = path.contains('.')
        ? path.substring(path.lastIndexOf('.') + 1).toLowerCase()
        : '';
    if (!FileChooser.audioExtensions.contains(extension)) {
      // A warning rather than a refusal would be worse: the decoder would
      // fail a minute into a job instead of now.
      setState(() => _error =
          'Vox Scripta cannot read .$extension files. '
          'It reads ${FileChooser.audioExtensions.take(6).join(', ')} and more.');
      return;
    }
    Navigator.of(context).pop(ImportChoice(audioPath: path));
  }
}
