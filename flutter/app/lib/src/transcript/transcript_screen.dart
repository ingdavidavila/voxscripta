import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import '../platform_traits.dart';
import 'review_panel.dart';
import 'transcript_model.dart';
import 'wording.dart';

/// The three outputs, and the evidence behind them.
class TranscriptScreen extends StatefulWidget {
  const TranscriptScreen({super.key, required this.model});

  final TranscriptModel model;

  @override
  State<TranscriptScreen> createState() => _TranscriptScreenState();
}

class _TranscriptScreenState extends State<TranscriptScreen> {
  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onChanged);
    widget.model.load();
  }

  @override
  void dispose() {
    widget.model.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final review = model.polish;

    return CallbackShortcuts(
      bindings: {
        // ⇧⌘C on a Mac, Ctrl+Shift+C elsewhere, matching the SwiftUI app's
        // shortcut and each platform's own modifier.
        SingleActivator(LogicalKeyboardKey.keyC,
            shift: true,
            meta: Platform.isMacOS,
            control: !Platform.isMacOS): _copy,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text(model.displayName, overflow: TextOverflow.ellipsis),
            actions: [
              if (review?.hasSomethingToShow ?? false)
                IconButton(
                  isSelected: model.showsReview,
                  icon: const Icon(Icons.verified_user_outlined),
                  selectedIcon: const Icon(Icons.verified_user),
                  tooltip: 'Show what polish changed, and what it refused.',
                  onPressed: model.toggleReview,
                ),
              IconButton(
                icon: const Icon(Icons.copy_all_outlined),
                tooltip: model.selected == null
                    ? 'Nothing to copy yet.'
                    : 'Copy the whole ${Wording.variantName(model.selected!).toLowerCase()} '
                        'transcript to the clipboard.',
                onPressed: model.selected == null ? null : _copy,
              ),
              _SaveButton(model: model, onSaved: _save),
              const SizedBox(width: 4),
            ],
          ),
          body: _body(model),
        ),
      ),
    );
  }

  Widget _body(TranscriptModel model) {
    if (model.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (model.error case final message? when model.summary == null) {
      return _Centred(
        icon: Icons.error_outline,
        title: 'This project could not be read',
        detail: message,
      );
    }
    if (model.availableVariants.isEmpty) {
      return const _Centred(
        icon: Icons.hourglass_empty,
        title: 'Nothing transcribed yet',
        detail: 'This project has no finished transcript. '
            'Run it, and the three variants appear here.',
      );
    }

    final review = model.polish;
    final showReview = model.showsReview && (review?.hasSomethingToShow ?? false);

    return Column(
      children: [
        _VariantBar(model: model),
        const Divider(height: 1),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final text = _TranscriptText(model: model);
              if (!showReview) return text;
              // Side by side where there is room; a full screen otherwise,
              // because a 300px review panel on a phone is neither.
              if (constraints.maxWidth < 720) return ReviewPanel(review: review!);
              return Row(
                // Stretch, not the default centre. Expanded governs the
                // horizontal axis only, so with the default the text pane took
                // its natural height and floated in the middle of the window —
                // which read as a placeholder rather than as a document.
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: text),
                  const VerticalDivider(width: 1),
                  SizedBox(width: 360, child: ReviewPanel(review: review!)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _copy() async {
    final model = widget.model;
    if (model.selected == null) return;
    await Clipboard.setData(ClipboardData(text: model.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Copied the ${Wording.variantName(model.selected!).toLowerCase()} '
          'transcript.'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Renders a format and reports it.
  ///
  /// Writing the bytes to a file the user chooses needs a save dialog, which
  /// needs a plugin this app does not have yet. Rather than a button that
  /// looks like it saves and does not, this renders through the engine and
  /// says how large the result is — which proves the export path end to end
  /// and is honest about the part that is missing.
  Future<void> _save(ExportFormat format) async {
    final model = widget.model;
    try {
      final bytes = await model.render(format);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${Wording.formatName(format)} rendered — '
            '${bytes.length} bytes. Choosing where to save it needs the file '
            'dialog, which is not wired up yet.'),
        duration: const Duration(seconds: 4),
      ));
    } on VoxScriptaException catch (failure) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }
}

/// The variant picker, with the counts beside it.
class _VariantBar extends StatelessWidget {
  const _VariantBar({required this.model});

  final TranscriptModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = model.selectedSummary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Flexible(
            child: SegmentedButton<TranscriptVariant>(
              segments: [
                for (final variant in model.availableVariants)
                  ButtonSegment(
                    value: variant,
                    label: Text(Wording.variantName(variant)),
                    tooltip: PlatformTraits.hasPointer
                        ? Wording.variantExplanation(variant)
                        : null,
                  ),
              ],
              selected: {if (model.selected != null) model.selected!},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => model.select(selection.first),
            ),
          ),
          const Spacer(),
          if (counts != null)
            Text(
              '${counts.words} words · ${counts.segments} segments',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

/// The transcript itself: selectable, scrollable, and nothing else.
class _TranscriptText extends StatelessWidget {
  const _TranscriptText({required this.model});

  final TranscriptModel model;

  @override
  Widget build(BuildContext context) {
    if (model.error case final message?) {
      return _Centred(
        icon: Icons.error_outline,
        title: 'That transcript could not be read',
        detail: message,
      );
    }
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        // Top-left, explicitly. Without it a transcript shorter than the
        // window floated in the vertical middle of the pane, which reads as a
        // placeholder rather than as the start of a document.
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            // A measure, not the window width. Running text at 1400px is
            // unreadable however much room the window has.
            constraints: const BoxConstraints(maxWidth: 760),
            child: SelectableText(
              model.text,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.55),
            ),
          ),
        ),
      ),
    );
  }
}

/// Save: a primary format on click, the rest behind the arrow.
class _SaveButton extends StatelessWidget {
  const _SaveButton({required this.model, required this.onSaved});

  final TranscriptModel model;
  final Future<void> Function(ExportFormat) onSaved;

  @override
  Widget build(BuildContext context) {
    final enabled = model.selected != null;
    return MenuAnchor(
      menuChildren: [
        for (final format in Wording.formatsFor(
            model.selected ?? TranscriptVariant.clean))
          MenuItemButton(
            onPressed: () => onSaved(format),
            child: Tooltip(
              message: Wording.formatExplanation(format),
              child: Text(Wording.formatName(format)),
            ),
          ),
        const Divider(height: 1),
        // A checkbox rather than a separate screen: it changes what the next
        // export contains and nothing else.
        CheckboxMenuButton(
          value: model.includeTimestamps,
          onChanged: (value) => model.setIncludeTimestamps(value ?? false),
          child: const Text('Include timestamps'),
        ),
      ],
      builder: (context, controller, child) => IconButton(
        icon: const Icon(Icons.download_outlined),
        tooltip: enabled
            ? 'Save this transcript. Formats and timestamps are in the menu.'
            : 'Nothing to save yet.',
        onPressed: !enabled
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

class _Centred extends StatelessWidget {
  const _Centred({required this.icon, required this.title, required this.detail});

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              SelectableText(detail,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}
