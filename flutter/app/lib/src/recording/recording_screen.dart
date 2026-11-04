import 'package:flutter/material.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import 'recording_model.dart';

/// Capturing the microphone.
///
/// The app was built around files that already existed, which is the wrong
/// shape for a phone: a person with something to transcribe is holding the
/// thing making the sound. So this writes a new original and hands it to the
/// same import path a chosen file takes — nothing downstream knows where the
/// audio came from.
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.model, this.onFinished});

  final RecordingModel model;

  /// Called with the finished file, so the shell can transcribe it.
  final void Function(BuildContext, RecordingResult)? onFinished;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  @override
  void initState() {
    super.initState();
    widget.model.addListener(_onChanged);
    widget.model.start();
  }

  @override
  void dispose() {
    widget.model.removeListener(_onChanged);
    widget.model.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final progress = model.progress;

    return PopScope(
      // Leaving mid-recording must not silently bin the audio. The model
      // finishes rather than discards on dispose; this just makes the choice
      // explicit while there is still something to choose.
      canPop: !model.isActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard(leaving: true);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_title(progress))),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (model.startFailure case final message?)
                    _Failure(message: message, directory: model.directory)
                  else ...[
                    Text(
                      formatRecordingClock(progress.elapsed),
                      style: Theme.of(context).textTheme.displayMedium?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                    ),
                    const SizedBox(height: 24),
                    _Meter(levels: model.levels, active: progress.state == RecordingState.recording),
                    const SizedBox(height: 32),
                    _Transport(
                      model: model,
                      onDiscard: () => _confirmDiscard(),
                      onFinish: _finish,
                    ),
                    if (progress.failure case final message?) ...[
                      const SizedBox(height: 24),
                      _WriteFailure(message: message),
                    ],
                    const SizedBox(height: 28),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.lock_outline,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text('Your audio never leaves this device',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _title(RecordingProgress progress) => switch (progress.state) {
        RecordingState.idle => 'Opening the microphone…',
        RecordingState.recording => 'Recording…',
        RecordingState.paused => 'Paused',
        RecordingState.unknownHandle => 'Recording',
      };

  void _finish() {
    final result = widget.model.finish();
    if (result == null || !mounted) return;
    widget.onFinished?.call(context, result);
  }

  Future<void> _confirmDiscard({bool leaving = false}) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this recording?'),
        content: const Text(
            'The audio recorded so far will be deleted. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (discard == true) {
      widget.model.discard();
      if (leaving) Navigator.of(context).pop();
    }
  }
}

/// A row of bars showing recent input level.
///
/// Drawn from the model's history so it scrolls leftwards as samples arrive,
/// without this view keeping state of its own.
class _Meter extends StatelessWidget {
  const _Meter({required this.levels, required this.active});

  final List<double> levels;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);

    return SizedBox(
      height: 56,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var index = 0; index < RecordingModel.meterHistory; index += 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: _Bar(
                // Right-aligned history: the newest sample is at the right end
                // and older ones scroll left, which is the direction a meter
                // is read.
                level: index >= RecordingModel.meterHistory - levels.length
                    ? levels[index - (RecordingModel.meterHistory - levels.length)]
                    : 0,
                colour: colour,
              ),
            ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.level, required this.colour});

  final double level;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
        width: 3,
        // A floor of 2px so silence reads as a line rather than as a gap —
        // the same choice the waveform makes.
        height: 2 + level.clamp(0.0, 1.0) * 50,
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(1.5),
        ),
      );
}

class _Transport extends StatelessWidget {
  const _Transport({
    required this.model,
    required this.onDiscard,
    required this.onFinish,
  });

  final RecordingModel model;
  final VoidCallback onDiscard;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final state = model.progress.state;
    final paused = state == RecordingState.paused;
    final live = state == RecordingState.recording || paused;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton.outlined(
          onPressed: live ? onDiscard : null,
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete this recording without keeping it.',
        ),
        const SizedBox(width: 20),
        IconButton.filled(
          iconSize: 32,
          onPressed: !live
              ? null
              : paused
                  ? model.resume
                  : model.pause,
          icon: Icon(paused ? Icons.play_arrow : Icons.pause),
          tooltip: paused
              ? 'Carry on recording into the same file.'
              : 'Stop capturing without ending the recording.',
        ),
        const SizedBox(width: 20),
        FilledButton.icon(
          onPressed: live ? onFinish : null,
          icon: const Icon(Icons.check),
          label: const Text('Finish'),
        ),
      ],
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.directory});

  final String message;
  final String directory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.mic_off_outlined, size: 48, color: theme.colorScheme.error),
        const SizedBox(height: 16),
        Text('The microphone could not be opened',
            style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        // The engine's own words. "No microphone is available" and "the
        // microphone did not start" are different problems.
        SelectableText(message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// Writing failed part-way through. The audio before that point is intact.
class _WriteFailure extends StatelessWidget {
  const _WriteFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Writing stopped',
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: theme.colorScheme.onErrorContainer)),
            const SizedBox(height: 4),
            SelectableText(
              '$message\n\nWhat was recorded before this is still on disk.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ],
        ),
      ),
    );
  }
}
