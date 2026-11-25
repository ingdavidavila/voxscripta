import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import '../l10n.dart';
import '../platform_traits.dart';
import 'file_saver.dart';
import 'review_panel.dart';
import 'transcript_model.dart';
import 'wording.dart';

/// The three outputs, and the evidence behind them.
class TranscriptScreen extends StatefulWidget {
  const TranscriptScreen(
      {super.key, required this.model, this.onRun, this.saver});

  final TranscriptModel model;

  /// Where a rendered transcript is written. Defaults to this platform's own.
  final FileSaver? saver;

  /// Starts the pipeline for a project that has no transcript yet. Null leaves
  /// the empty state as a statement rather than an offer.
  final void Function(BuildContext)? onRun;

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
                  tooltip: context.l10n.reviewToggleTooltip,
                  onPressed: model.toggleReview,
                ),
              IconButton(
                icon: const Icon(Icons.copy_all_outlined),
                tooltip: model.selected == null
                    ? context.l10n.nothingToCopy
                    : context.l10n.copyTranscriptTooltip(
                        Wording.variantName(context.l10n, model.selected!)
                            .toLowerCase()),
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
        title: context.l10n.projectUnreadableTitle,
        detail: message,
      );
    }
    if (model.availableVariants.isEmpty) {
      return _Centred(
        icon: Icons.hourglass_empty,
        title: context.l10n.noTranscriptTitle,
        detail: context.l10n.noTranscriptDetail,
        // An offer rather than an instruction: the audio is right there and
        // the engine can resume from wherever a previous run stopped.
        action: widget.onRun == null
            ? null
            : FilledButton.icon(
                onPressed: () => widget.onRun!(context),
                icon: const Icon(Icons.play_arrow),
                label: Text(context.l10n.transcribeIt),
              ),
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
      content: Text(context.l10n.copiedTranscript(
          Wording.variantName(context.l10n, model.selected!).toLowerCase())),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Renders a format through the engine and writes it where the person says.
  ///
  /// A cancelled dialog is an answer and says nothing. A failure says why.
  Future<void> _save(ExportFormat format) async {
    final model = widget.model;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final saver = widget.saver ?? FileSaver.forPlatform();
    try {
      final bytes = await model.render(format);
      final name = safeFileName(model.displayName, format.wireName);
      final outcome = await saver.save(
        suggestedName: name,
        mimeType: mimeTypeFor(format.wireName),
        bytes: bytes,
        dialogTitle: l10n.saveDialogTitle,
      );
      if (!mounted) return;
      switch (outcome) {
        case Saved(:final where):
          messenger.showSnackBar(SnackBar(content: Text(l10n.savedTo(where))));
        case SaveCancelled():
          break;
        case SaveFailed(:final reason):
          messenger
              .showSnackBar(SnackBar(content: Text(l10n.saveFailed(reason))));
      }
    } on VoxScriptaException catch (failure) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(failure.message)));
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
      // A Wrap rather than a Row with a Spacer: the Spacer took half the row and
      // squeezed the picker until "Verbatim" wrapped to "Verba / tim" at phone
      // width. Here the counts share the line when there is room and drop to
      // their own line when there is not.
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 8,
        children: [
          SegmentedButton<TranscriptVariant>(
              segments: [
                for (final variant in model.availableVariants)
                  ButtonSegment(
                    value: variant,
                    label: Text(Wording.variantName(context.l10n, variant)),
                    tooltip: PlatformTraits.hasPointer
                        ? Wording.variantExplanation(context.l10n, variant)
                        : null,
                  ),
              ],
              selected: {if (model.selected != null) model.selected!},
              showSelectedIcon: false,
              onSelectionChanged: (selection) => model.select(selection.first),
          ),
          if (counts != null)
            Text(
              context.l10n.wordsAndSegments(counts.words, counts.segments),
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
        title: context.l10n.transcriptUnreadableTitle,
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
              message: Wording.formatExplanation(context.l10n, format),
              child: Text(Wording.formatName(context.l10n, format)),
            ),
          ),
        const Divider(height: 1),
        // A checkbox rather than a separate screen: it changes what the next
        // export contains and nothing else.
        CheckboxMenuButton(
          value: model.includeTimestamps,
          onChanged: (value) => model.setIncludeTimestamps(value ?? false),
          child: Text(context.l10n.includeTimestamps),
        ),
      ],
      builder: (context, controller, child) => IconButton(
        icon: const Icon(Icons.download_outlined),
        tooltip: enabled
            ? context.l10n.saveTranscriptTooltip
            : context.l10n.nothingToSave,
        onPressed: !enabled
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

class _Centred extends StatelessWidget {
  const _Centred({
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
              if (action case final widget?) ...[
                const SizedBox(height: 20),
                widget,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
