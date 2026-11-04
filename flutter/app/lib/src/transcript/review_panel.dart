import 'package:flutter/material.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

import 'wording.dart';

/// What POLISH did, and what it refused.
///
/// The stage that can change what a sentence means is the one stage whose
/// workings are shown rather than assumed. A reader should be able to see
/// every sentence the gauntlet rejected and the reason it gave.
class ReviewPanel extends StatelessWidget {
  const ReviewPanel({super.key, required this.review});

  final PolishReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!review.ran) {
      return _Padded(
        children: [
          Row(children: [
            Icon(Icons.warning_amber_outlined, color: theme.colorScheme.tertiary),
            const SizedBox(width: 8),
            Text('Polish did not run', style: theme.textTheme.titleSmall),
          ]),
          const SizedBox(height: 8),
          // Verbatim. §26 asks that a missing polished transcript never be
          // unexplained, and paraphrasing the engine would lose the detail
          // that makes it actionable.
          SelectableText(
            review.skipReason ?? 'No reason was recorded.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      );
    }

    return _Padded(
      children: [
        Text('Polish review', style: theme.textTheme.titleSmall),
        const SizedBox(height: 10),
        _Count(label: 'Accepted', value: review.accepted),
        _Count(label: 'Accepted after a retry', value: review.acceptedAfterRetry),
        _Count(label: 'Kept the clean text', value: review.keptClean),
        const Divider(height: 24),
        if (review.flagged.isEmpty)
          Row(children: [
            Icon(Icons.verified_outlined, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Every sentence passed.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ])
        else
          for (final sentence in review.flagged) _FlaggedRow(sentence: sentence),
      ],
    );
  }
}

class _Padded extends StatelessWidget {
  const _Padded({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: children,
        ),
      );
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              '$value',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }
}

/// One sentence worth reading, with its before and after.
class _FlaggedRow extends StatelessWidget {
  const _FlaggedRow({required this.sentence});

  final FlaggedSentence sentence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kept = !sentence.disposition.keptModelText;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(
                kept ? Icons.shield_outlined : Icons.replay,
                size: 16,
                // A rejection is the gauntlet working, not an error — so it is
                // not coloured as a failure.
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(Wording.dispositionName(sentence.disposition),
                  style: theme.textTheme.labelMedium),
            ]),
            const SizedBox(height: 8),
            _Line(label: 'Clean', text: sentence.original),
            const SizedBox(height: 4),
            _Line(label: 'Model', text: sentence.revised),
            if (sentence.reasons.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final reason in sentence.reasons)
                Text('• $reason',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(child: SelectableText(text, style: theme.textTheme.bodySmall)),
      ],
    );
  }
}
