import 'package:flutter/material.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import 'processing_model.dart';
import 'waveform_painter.dart';

/// What the user watches while a job runs.
///
/// §18 asks that this never look frozen. The waveform appears as soon as
/// analysis finishes — well before transcription starts — so there is
/// something real on screen during the longest phase, and the phase list shows
/// *where* the work is rather than only how far along it is.
class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({super.key, required this.model, this.onFinished});

  final ProcessingModel model;

  /// Called once the job reaches a terminal state, so the shell can move on to
  /// the transcript. Null leaves the screen showing the outcome.
  final void Function(BuildContext, JobProgress)? onFinished;

  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  bool _announced = false;

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
    if (!mounted) return;
    setState(() {});
    if (widget.model.isFinished && !_announced) {
      _announced = true;
      // After the frame, because a screen must not be replaced from inside the
      // build that is drawing it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onFinished?.call(context, widget.model.progress);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final progress = model.progress;

    return Scaffold(
      appBar: AppBar(
        title: Text(model.displayName, overflow: TextOverflow.ellipsis),
        actions: [
          if (!model.isFinished && model.startFailure == null)
            TextButton(
              onPressed: model.cancel,
              child: const Text('Stop'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (model.startFailure case final message?)
            _Failure(title: 'This job could not start', detail: message)
          else ...[
            _Header(progress: progress, audio: model.audio),
            const SizedBox(height: 20),
            _Waveform(model: model),
            const SizedBox(height: 24),
            _Phases(current: progress.state),
            if (progress.failure case final message?) ...[
              const SizedBox(height: 24),
              _Failure(title: 'This job stopped', detail: message),
            ],
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.progress, required this.audio});

  final JobProgress progress;
  final AudioFacts? audio;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (progress.fraction * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                progress.detail.isEmpty ? 'Starting…' : progress.detail,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Text('$percent%',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          // Determinate from the first report. An indeterminate bar says "I do
          // not know", and the engine does know.
          value: progress.fraction.clamp(0.0, 1.0),
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
        if (audio?.speechRegions case final regions?) ...[
          const SizedBox(height: 10),
          Text(
            '$regions speech regions · '
            '${((audio?.speechFraction ?? 0) * 100).round()}% of the recording '
            'is speech',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        if (_polishNotice(audio) case final notice?) ...[
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.schedule, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(notice,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ]),
        ],
      ],
    );
  }

  /// Shown as soon as the duration is known rather than when polishing starts,
  /// so a long job can be stopped before it begins instead of being mistaken
  /// for a hang an hour in. The estimate itself is the engine's.
  static String? _polishNotice(AudioFacts? audio) {
    final estimate = audio?.polishEstimate;
    if (estimate == null || estimate.inSeconds <= 300) return null;
    final minutes = (estimate.inSeconds / 60).round();
    final said = minutes < 90
        ? '$minutes minutes'
        : '${(minutes / 60).toStringAsFixed(1).replaceAll('.0', '')} hours';
    return 'Polishing will take about $said — it makes one request to the '
        'language model for every sentence. Transcription finishes long before '
        'that, and you can read it while polishing continues.';
  }
}

class _Waveform extends StatelessWidget {
  const _Waveform({required this.model});

  final ProcessingModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pairs = model.waveform;

    return Container(
      height: 96,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: pairs == null
          ? Center(
              child: Text('Reading audio…',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            )
          : CustomPaint(
              painter: WaveformPainter(
                pairs: pairs,
                trace: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                speech: theme.colorScheme.primary.withValues(alpha: 0.16),
                speechSpans: model.audio?.speechSpans ?? const [],
                duration: model.audio?.duration ?? Duration.zero,
              ),
              size: Size.infinite,
            ),
    );
  }
}

/// The pipeline's phases, with the current one marked.
class _Phases extends StatelessWidget {
  const _Phases({required this.current});

  final JobState current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reached = _indexOf(current);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < processingPhases.length; index += 1)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(width: 20, child: _mark(context, index, reached)),
                const SizedBox(width: 10),
                Text(
                  processingPhases[index].$2,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: index == reached
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: index == reached ? FontWeight.w500 : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _mark(BuildContext context, int index, int reached) {
    final theme = Theme.of(context);
    final done = current == JobState.complete || index < reached;
    if (done) {
      return Icon(Icons.check_circle, size: 16, color: theme.colorScheme.primary);
    }
    if (index == reached) {
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return Icon(Icons.circle_outlined,
        size: 14, color: theme.colorScheme.outlineVariant);
  }

  /// Which phase the job is in, or -1 before the first one.
  ///
  /// A failed or cancelled job keeps whichever phase it stopped in marked as
  /// current rather than showing everything done, because it is not.
  static int _indexOf(JobState state) {
    for (var index = 0; index < processingPhases.length; index += 1) {
      if (processingPhases[index].$1 == state) return index;
    }
    return state == JobState.complete ? processingPhases.length : -1;
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.title, required this.detail});

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer)),
            const SizedBox(height: 6),
            // The engine's own words. A job that stopped has a reason, and
            // paraphrasing it loses the part that makes it fixable.
            SelectableText(detail,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer)),
          ],
        ),
      ),
    );
  }
}
