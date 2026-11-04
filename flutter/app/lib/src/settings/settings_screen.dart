import 'package:flutter/material.dart';

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
  const SettingsScreen({super.key, required this.model, this.accountSection});

  final SettingsModel model;

  /// The account rows, when this build has an account service. Supplied from
  /// outside so that settings stays a view of the engine's configuration and
  /// knows nothing about sign-in.
  final Widget? accountSection;

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
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: model.hasOverrides ? model.reset : null,
            child: const Text('Reset to defaults'),
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
        _Section(title: 'Silence detection', children: [
          _Slider(
            label: 'Threshold above noise',
            help: 'How far above the measured background noise a sound must be '
                'to count as speech. Raise it for a noisy recording.',
            value: model.silenceMarginDB,
            min: 3,
            max: 20,
            divisions: 17,
            format: (v) => '${v.round()} dB',
            onChanged: (v) => model.setNested('silence', 'marginDB', v.roundToDouble()),
          ),
          _Slider(
            label: 'Shortest pause',
            help: 'A quiet stretch shorter than this is treated as part of the '
                'speech, not as a pause.',
            value: model.minimumSilenceSeconds,
            min: 0.2,
            max: 2,
            divisions: 18,
            format: (v) => '${v.toStringAsFixed(1)} s',
            onChanged: (v) => model.setNested('silence', 'minSilenceDuration', v),
          ),
          _Slider(
            label: 'Padding after speech',
            help: 'Silence kept after each phrase, so word endings are not '
                'clipped when silence is removed.',
            value: model.padTrailSeconds,
            min: 0,
            max: 1,
            divisions: 20,
            format: (v) => '${v.toStringAsFixed(2)} s',
            onChanged: (v) => model.setNested('silence', 'padTrail', v),
          ),
        ]),
        _Section(
          title: 'Segmentation',
          footer: 'Segments are internal. They set how often work is saved, '
              'not how the transcript reads.',
          children: [
            _Slider(
              label: 'Maximum segment length',
              help: 'The longest stretch of audio transcribed as one unit. '
                  'Shorter segments save progress more often.',
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
          title: 'Transcription',
          footer: 'More at once is faster up to a point, and costs memory. '
              'Four is measured rather than guessed.',
          children: [
            _Switch(
              label: 'Detect language',
              help: 'Tries the languages this machine can transcribe on a short '
                  'sample and uses whichever the engine recognises confidently. '
                  'The setting below is the fallback. Nothing is downloaded.',
              value: model.detectLanguage,
              onChanged: (v) => model.set('detectLanguage', v),
            ),
            _LocalePicker(model: model),
            if (!model.textStagesSupportedHere)
              const _Notice(
                icon: Icons.warning_amber_outlined,
                text: 'Verbatim only in this language. Clean and Polished need '
                    'lexicons Vox Scripta does not have yet.',
              )
            else if (!model.polishSupportedHere)
              const _Notice(
                icon: Icons.shield_outlined,
                text: 'Polished is unavailable in this language. The checks '
                    'that catch a reversed meaning have not been proven here, '
                    'so the pass is withheld rather than run unguarded.',
              ),
            _Stepper(
              label: 'Segments at once',
              help: 'How many segments are transcribed concurrently.',
              value: model.concurrency,
              min: 1,
              max: 8,
              onChanged: (v) => model.set('concurrency', v),
            ),
          ],
        ),
        _Section(
          title: 'Clean',
          footer: 'Clean uses fixed rules only. No language model is involved, '
              'and every edit is recorded.',
          children: [
            _Switch(
              label: 'Remove fillers',
              help: 'Drops “um”, “uh” and the like.',
              value: model.removeFillers,
              onChanged: (v) => model.setNested('clean', 'removeFillers', v),
            ),
            _Switch(
              label: 'Collapse stutters',
              help: 'Turns “the the the” into “the”.',
              value: model.collapseRepetitions,
              onChanged: (v) => model.setNested('clean', 'collapseRepetitions', v),
            ),
            _Switch(
              label: 'Drop low-confidence words',
              help: 'Removes words the recogniser was unsure of.',
              value: model.dropLowConfidence,
              onChanged: (v) => model.setNested('clean', 'dropLowConfidence', v),
            ),
          ],
        ),
        _PolishSection(model: model),
        _Section(
          title: 'Storage and privacy',
          // The claim is about audio and transcripts, not about the
          // network, because a build that sells a subscription has to reach
          // a store. A promise that holds for one flavour and not another is
          // worse than a narrower one that holds for both.
          footer: widget.accountSection == null
              ? 'Transcription runs entirely on this machine. No recording '
                  'and no transcript is ever uploaded, and there is no '
                  'telemetry.'
              : 'Transcription runs entirely on this machine. No recording '
                  'and no transcript is ever uploaded, and there is no '
                  'telemetry. An account is optional and carries only your '
                  'email address, for signing in.',
          children: [
            _Switch(
              label: 'Keep working files',
              help: 'Keeps the scratch audio after a job finishes. It is about '
                  '1.4 GB for a six-hour recording, and the transcripts do not '
                  'need it.',
              value: model.keepIntermediates,
              onChanged: (v) => model.set('keepIntermediates', v),
            ),
            _Readout(
              label: 'Projects folder',
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
    return _Section(
      title: 'Polished',
      footer: 'Polish rewrites sentence by sentence and checks each rewrite '
          'against the original. A rewrite that fails is discarded and the '
          'clean sentence stands.',
      children: [
        _Switch(
          label: 'Create a polished transcript',
          help: model.polishSupportedHere
              ? 'Runs the model pass after Clean.'
              : 'Unavailable in the selected language.',
          value: model.polishEnabled && model.polishSupportedHere,
          onChanged:
              model.polishSupportedHere ? (v) => model.set('polishEnabled', v) : null,
        ),
        _Dropdown(
          label: 'Language model',
          help: 'Which model to prefer. A named model that is unavailable is '
              'refused rather than quietly swapped for another.',
          value: model.polishBackend,
          items: const {
            'automatic': 'Best available',
            'system': 'Apple Intelligence',
            'bundled': 'Bundled model',
          },
          onChanged: model.polishEnabled ? (v) => model.set('polishBackend', v) : null,
        ),
        _Readout(
          label: 'Will use',
          // The engine's own answer, in the same words the provenance records.
          value: polish?.effective ??
              polish?.unavailableReason ??
              'unavailable — polish will be skipped',
        ),
        _Readout(
          label: 'Apple Intelligence',
          value: (polish?.systemModelAvailable ?? false) ? 'Available' : 'Unavailable',
        ),
        _Readout(
          label: 'Bundled model',
          value: polish?.bundledModel ?? 'Not included',
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
      return const _Row(
        label: 'Language',
        help: 'No transcription languages were reported.',
        control: SizedBox.shrink(),
      );
    }
    return _Row(
      label: 'Language',
      help: 'The language spoken in the recording. Getting this wrong costs '
          'accuracy more than any other setting.',
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
