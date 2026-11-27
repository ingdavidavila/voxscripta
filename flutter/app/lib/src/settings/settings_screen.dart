import 'package:flutter/material.dart';

import '../l10n.dart';
import '../platform_traits.dart';
import 'settings_model.dart';

/// Advanced settings, deliberately out of the main workflow.
///
/// Every default shown here comes from the engine, and every label is the
/// wording the SwiftUI app uses. A settings screen is where two interfaces
/// drift first: it is nothing but names for the engine's own numbers, and
/// inventing either the names or the numbers would be inventing a second
/// engine.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.model,
    this.accountSection,
    this.onReportProblem,
  });

  final SettingsModel model;

  /// The account rows, when this build has an account service. Supplied from
  /// outside so that settings stays a view of the engine's configuration and
  /// knows nothing about sign-in.
  final Widget? accountSection;

  /// Opens a report about this installation. Null hides the row.
  final VoidCallback? onReportProblem;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.settingsTitle),
        actions: [
          TextButton(
            onPressed: model.hasOverrides ? model.reset : null,
            child: Text(context.l10n.resetToDefaults),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _body(model),
    );
  }

  Widget _body(SettingsModel model) {
    if (model.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (model.error case final message?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: SelectableText(message, textAlign: TextAlign.center),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        ? widget.accountSection,
        if (widget.onReportProblem case final report?)
          ListTile(
            leading: const Icon(Icons.bug_report_outlined),
            title: Text(context.l10n.reportProblem),
            subtitle: Text(context.l10n.reportProblemHelp),
            onTap: report,
          ),
        _Section(title: context.l10n.sectionSilence, children: [
          _Slider(
            label: context.l10n.silenceThreshold,
            help: context.l10n.silenceThresholdHelp,
            value: model.silenceMarginDB,
            min: 3,
            max: 20,
            divisions: 17,
            format: (v) => '${v.round()} dB',
            onChanged: (v) => model.setNested('silence', 'marginDB', v.roundToDouble()),
          ),
          _Slider(
            label: context.l10n.shortestPause,
            help: context.l10n.shortestPauseHelp,
            value: model.minimumSilenceSeconds,
            min: 0.2,
            max: 2,
            divisions: 18,
            format: (v) => '${v.toStringAsFixed(1)} s',
            onChanged: (v) => model.setNested('silence', 'minSilenceDuration', v),
          ),
          _Slider(
            label: context.l10n.paddingAfterSpeech,
            help: context.l10n.paddingAfterSpeechHelp,
            value: model.padTrailSeconds,
            min: 0,
            max: 1,
            divisions: 20,
            format: (v) => '${v.toStringAsFixed(2)} s',
            onChanged: (v) => model.setNested('silence', 'padTrail', v),
          ),
        ]),
        _Section(
          title: context.l10n.sectionSegmentation,
          footer: context.l10n.segmentationFooter,
          children: [
            _Slider(
              label: context.l10n.maxSegmentLength,
              help: context.l10n.maxSegmentLengthHelp,
              value: model.maximumChunkSeconds,
              min: 60,
              max: 600,
              divisions: 18,
              format: (v) => '${v.round()} s',
              onChanged: (v) =>
                  model.setNested('chunking', 'maxDuration', v.roundToDouble()),
            ),
          ],
        ),
        _Section(
          title: context.l10n.sectionTranscription,
          footer: context.l10n.transcriptionFooter,
          children: [
            _Switch(
              label: context.l10n.detectLanguage,
              help: context.l10n.detectLanguageHelp,
              value: model.detectLanguage,
              onChanged: (v) => model.set('detectLanguage', v),
            ),
            _LocalePicker(model: model),
            if (!model.textStagesSupportedHere)
              _Notice(
                icon: Icons.warning_amber_outlined,
                text: context.l10n.verbatimOnlyNotice,
              )
            else if (!model.polishSupportedHere)
              _Notice(
                icon: Icons.shield_outlined,
                text: context.l10n.polishedUnavailableNotice,
              ),
            _Stepper(
              label: context.l10n.segmentsAtOnce,
              help: context.l10n.segmentsAtOnceHelp,
              value: model.concurrency,
              min: 1,
              max: 8,
              onChanged: (v) => model.set('concurrency', v),
            ),
          ],
        ),
        _Section(
          title: context.l10n.variantClean,
          footer: context.l10n.cleanFooter,
          children: [
            _Switch(
              label: context.l10n.removeFillers,
              help: context.l10n.removeFillersHelp,
              value: model.removeFillers,
              onChanged: (v) => model.setNested('clean', 'removeFillers', v),
            ),
            _Switch(
              label: context.l10n.collapseStutters,
              help: context.l10n.collapseStuttersHelp,
              value: model.collapseRepetitions,
              onChanged: (v) => model.setNested('clean', 'collapseRepetitions', v),
            ),
            _Switch(
              label: context.l10n.dropLowConfidence,
              help: context.l10n.dropLowConfidenceHelp,
              value: model.dropLowConfidence,
              onChanged: (v) => model.setNested('clean', 'dropLowConfidence', v),
            ),
          ],
        ),
        _PolishSection(model: model),
        _Section(
          title: context.l10n.sectionStorage,
          // The claim is about audio and transcripts, not about the
          // network, because a build that sells a subscription has to reach
          // a store. A promise that holds for one flavour and not another is
          // worse than a narrower one that holds for both.
          footer: widget.accountSection == null
              ? context.l10n.privacyFooter
              : context.l10n.privacyFooterWithAccount,
          children: [
            _Switch(
              label: context.l10n.keepWorkingFiles,
              help: context.l10n.keepWorkingFilesHelp,
              value: model.keepIntermediates,
              onChanged: (v) => model.set('keepIntermediates', v),
            ),
            _Readout(
              label: context.l10n.projectsFolder,
              value: model.libraryDirectory,
              selectable: true,
            ),
          ],
        ),
      ],
    );
  }
}

/// Polish, and what would actually run.
class _PolishSection extends StatelessWidget {
  const _PolishSection({required this.model});

  final SettingsModel model;

  @override
  Widget build(BuildContext context) {
    final polish = model.capabilities?.polish;
    // Apple Intelligence exists only on Apple's platforms. Offering it elsewhere
    // is a claim the platform cannot keep, so the choice and its readout are not
    // shown there, and a stored 'system' choice reads as automatic.
    final platform = Theme.of(context).platform;
    final apple =
        platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
    final backend =
        !apple && model.polishBackend == 'system' ? 'automatic' : model.polishBackend;
    return _Section(
      title: context.l10n.variantPolished,
      footer: context.l10n.polishFooter,
      children: [
        _Switch(
          label: context.l10n.createPolished,
          help: model.polishSupportedHere
              ? context.l10n.polishRunsAfterClean
              : context.l10n.polishUnavailableInLanguage,
          value: model.polishEnabled && model.polishSupportedHere,
          onChanged:
              model.polishSupportedHere ? (v) => model.set('polishEnabled', v) : null,
        ),
        _Dropdown(
          label: context.l10n.languageModel,
          help: context.l10n.languageModelHelp,
          value: backend,
          items: {
            'automatic': context.l10n.backendAutomatic,
            if (apple) 'system': context.l10n.backendSystem,
            'bundled': context.l10n.backendBundled,
          },
          onChanged: model.polishEnabled ? (v) => model.set('polishBackend', v) : null,
        ),
        _Readout(
          label: context.l10n.willUse,
          // The engine's own answer, in the same words the provenance records.
          value: polish?.effective ??
              polish?.unavailableReason ??
              context.l10n.polishWillBeSkipped,
        ),
        if (apple)
          _Readout(
            label: context.l10n.backendSystem,
            value: (polish?.systemModelAvailable ?? false)
                ? context.l10n.available
                : context.l10n.unavailable,
          ),
        _Readout(
          label: context.l10n.backendBundled,
          value: polish?.bundledModel ?? context.l10n.notIncluded,
        ),
      ],
    );
  }
}

// ── Pieces ─────────────────────────────────────────────────────────────────

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children, this.footer});

  final String title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: 0.8,
                )),
          ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: children),
          ),
          if (footer case final text?)
            Padding(
              padding: const EdgeInsets.only(left: 4, top: 8),
              child: Text(text,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}

/// A row whose help text becomes a tooltip where there is a pointer, and a
/// subtitle where there is not — because a tooltip a finger cannot summon is
/// the same as no explanation at all.
class _Row extends StatelessWidget {
  const _Row({required this.label, required this.help, required this.control});

  final String label;
  final String? help;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    final showsHelpInline = !PlatformTraits.hasPointer && help != null;
    final tile = ListTile(
      title: Text(label),
      subtitle: showsHelpInline ? Text(help!) : null,
      trailing: control,
    );
    if (help == null || showsHelpInline) return tile;
    return Tooltip(
      message: help!,
      waitDuration: const Duration(milliseconds: 600),
      child: tile,
    );
  }
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.help,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final String help;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(min, max);
    return _Row(
      label: label,
      help: help,
      control: SizedBox(
        width: 260,
        child: Row(
          children: [
            Expanded(
              child: Slider(
                value: clamped,
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
              ),
            ),
            SizedBox(
              width: 64,
              child: Text(
                format(clamped),
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch({
    required this.label,
    required this.help,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String help;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => _Row(
        label: label,
        help: help,
        control: Switch(value: value, onChanged: onChanged),
      );
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.help,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final String help;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => _Row(
        label: label,
        help: help,
        control: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.remove),
              onPressed: value > min ? () => onChanged(value - 1) : null,
            ),
            SizedBox(
              width: 24,
              child: Text('$value',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: value < max ? () => onChanged(value + 1) : null,
            ),
          ],
        ),
      );
}

class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.label,
    required this.help,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String help;
  final String value;
  final Map<String, String> items;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => _Row(
        label: label,
        help: help,
        control: DropdownButton<String>(
          value: items.containsKey(value) ? value : items.keys.first,
          underline: const SizedBox.shrink(),
          items: [
            for (final entry in items.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged:
              onChanged == null ? null : (v) => v == null ? null : onChanged!(v),
        ),
      );
}

class _LocalePicker extends StatelessWidget {
  const _LocalePicker({required this.model});

  final SettingsModel model;

  @override
  Widget build(BuildContext context) {
    final locales = model.capabilities?.locales ?? const [];
    if (locales.isEmpty) {
      return _Row(
        label: context.l10n.settingsLanguage,
        help: context.l10n.noLanguagesReported,
        control: const SizedBox.shrink(),
      );
    }
    return _Row(
      label: context.l10n.settingsLanguage,
      help: context.l10n.settingsLanguageHelp,
      control: DropdownButton<String>(
        value: model.capabilities?.forIdentifier(model.locale) == null
            ? locales.first.identifier
            : model.locale,
        underline: const SizedBox.shrink(),
        items: [
          for (final option in locales)
            DropdownMenuItem(
              value: option.identifier,
              child: Text(option.displayName),
            ),
        ],
        onChanged: (value) => value == null ? null : model.set('locale', value),
      ),
    );
  }
}

/// A label and a value the engine supplied. Not editable — these are facts
/// about the machine, not choices.
class _Readout extends StatelessWidget {
  const _Readout({
    required this.label,
    required this.value,
    this.selectable = false,
  });

  final String label;
  final String value;

  /// Paths are selectable so they can be copied; short answers are not,
  /// because a selectable word in a settings list is just a snag.
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return ListTile(
      title: Text(label),
      subtitle: selectable
          ? SelectableText(value, style: style)
          : null,
      trailing: selectable
          ? null
          : ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(value, textAlign: TextAlign.end, style: style),
            ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}
