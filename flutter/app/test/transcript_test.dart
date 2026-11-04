import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/transcript/transcript_model.dart';
import 'package:voxscripta/src/transcript/transcript_screen.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The transcript screen.
///
/// What is worth pinning here is not that text appears — it is the behaviour a
/// user would be misled by if it were wrong: that the picker only offers
/// transcripts that exist, that a declined polish says why instead of showing
/// an empty panel, and that a rejected sentence is shown as the gauntlet
/// working rather than as an error.
void main() {
  ProjectSummary summaryWith({
    List<TranscriptVariant> variants = const [
      TranscriptVariant.verbatim,
      TranscriptVariant.clean,
      TranscriptVariant.polished,
    ],
    PolishReview? polish,
  }) =>
      ProjectSummary(
        variants: [
          for (final variant in variants)
            VariantSummary(variant: variant, words: 120, segments: 8),
        ],
        polish: polish ??
            const PolishReview(
              ran: true,
              skipReason: null,
              accepted: 7,
              acceptedAfterRetry: 1,
              keptClean: 0,
              flagged: [],
            ),
      );

  Future<TranscriptModel> show(
    WidgetTester tester, {
    required ProjectSummary summary,
    Map<TranscriptVariant, String> texts = const {},
    TranscriptVariant preferred = TranscriptVariant.clean,
  }) async {
    final model = TranscriptModel(
      source: _StubSource(summary: summary, texts: texts),
      projectPath: '/library/Interview.voxscripta',
      displayName: 'Interview.m4a',
      preferred: preferred,
    );
    await tester.pumpWidget(MaterialApp(home: TranscriptScreen(model: model)));
    await tester.pumpAndSettle();
    return model;
  }

  testWidgets('shows the preferred variant and its counts', (tester) async {
    await show(tester,
        summary: summaryWith(),
        texts: {TranscriptVariant.clean: 'The harbour was quiet that morning.'});

    expect(find.text('The harbour was quiet that morning.'), findsOne);
    expect(find.text('120 words · 8 segments'), findsOne);
    expect(find.text('Clean'), findsOne);
    expect(find.text('Polished'), findsOne);
  });

  testWidgets('only offers transcripts that exist', (tester) async {
    // A project that stopped after CLEAN has no polished transcript, and
    // offering one would open an empty pane.
    await show(tester,
        summary: summaryWith(variants: const [
          TranscriptVariant.verbatim,
          TranscriptVariant.clean,
        ]));

    expect(find.text('Verbatim'), findsOne);
    expect(find.text('Clean'), findsOne);
    expect(find.text('Polished'), findsNothing);
  });

  testWidgets('falls back when the preferred variant is absent', (tester) async {
    final model = await show(tester,
        summary: summaryWith(variants: const [TranscriptVariant.verbatim]),
        preferred: TranscriptVariant.polished);
    expect(model.selected, TranscriptVariant.verbatim);
  });

  testWidgets('switching variant loads that text', (tester) async {
    await show(tester, summary: summaryWith(), texts: {
      TranscriptVariant.clean: 'Tidied by rules.',
      TranscriptVariant.verbatim: 'Um, tidied, uh, by rules.',
    });
    expect(find.text('Tidied by rules.'), findsOne);

    await tester.tap(find.text('Verbatim'));
    await tester.pumpAndSettle();
    expect(find.text('Um, tidied, uh, by rules.'), findsOne);
  });

  testWidgets('a project with nothing transcribed says so', (tester) async {
    await show(tester, summary: summaryWith(variants: const []));
    expect(find.text('Nothing transcribed yet'), findsOne);
  });

  testWidgets('a declined polish shows the engine\'s reason', (tester) async {
    final model = await show(tester,
        summary: summaryWith(
          variants: const [TranscriptVariant.verbatim, TranscriptVariant.clean],
          polish: const PolishReview(
            ran: false,
            skipReason: 'Apple Intelligence is unavailable on this machine',
            accepted: 0,
            acceptedAfterRetry: 0,
            keptClean: 0,
            flagged: [],
          ),
        ));

    model.toggleReview();
    await tester.pumpAndSettle();

    expect(find.text('Polish did not run'), findsOne);
    // §26: never unexplained, and never paraphrased.
    expect(find.textContaining('Apple Intelligence is unavailable'), findsOne);
  });

  testWidgets('a rejected sentence shows both texts and the reason',
      (tester) async {
    final model = await show(tester,
        summary: summaryWith(
          polish: const PolishReview(
            ran: true,
            skipReason: null,
            accepted: 40,
            acceptedAfterRetry: 0,
            keptClean: 1,
            flagged: [
              FlaggedSentence(
                disposition: PolishDisposition.fellBackToClean,
                original: 'we did not ship on Friday',
                revised: 'we shipped on Friday',
                reasons: ['polarity reversed'],
              ),
            ],
          ),
        ));

    model.toggleReview();
    await tester.pumpAndSettle();

    expect(find.text('Kept the clean text'), findsAtLeast(1));
    expect(find.text('we did not ship on Friday'), findsOne);
    expect(find.text('we shipped on Friday'), findsOne);
    expect(find.text('• polarity reversed'), findsOne);
  });

  testWidgets('no review button when there is nothing to review',
      (tester) async {
    await show(tester,
        summary: summaryWith(
          polish: const PolishReview(
            ran: false,
            skipReason: null,
            accepted: 0,
            acceptedAfterRetry: 0,
            keptClean: 0,
            flagged: [],
          ),
        ));
    expect(find.byIcon(Icons.verified_user_outlined), findsNothing);
  });

  group('TranscriptModel', () {
    test('the timestamps choice reaches the export', () async {
      final source = _StubSource(summary: summaryWith(), texts: const {});
      final model = TranscriptModel(
        source: source,
        projectPath: '/p',
        displayName: 'p',
      );
      await model.load();

      await model.render(ExportFormat.subRip);
      expect(source.lastOptions?.includeTimestamps, isFalse);

      model.setIncludeTimestamps(true);
      await model.render(ExportFormat.subRip);
      expect(source.lastOptions?.includeTimestamps, isTrue);
    });

    test('exporting with no transcript throws rather than writing nothing',
        () async {
      final model = TranscriptModel(
        source: _StubSource(summary: summaryWith(variants: const []), texts: const {}),
        projectPath: '/p',
        displayName: 'p',
      );
      await model.load();
      expect(() => model.render(ExportFormat.plainText),
          throwsA(isA<VoxScriptaException>()));
    });
  });
}

class _StubSource implements TranscriptSource {
  _StubSource({required ProjectSummary summary, this.texts = const {}})
      : summaryValue = summary;

  final ProjectSummary summaryValue;
  final Map<TranscriptVariant, String> texts;
  ExportOptions? lastOptions;

  @override
  ProjectSummary summary(String projectPath) => summaryValue;

  @override
  Future<Uint8List> export({
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
    ExportOptions? options,
  }) async {
    lastOptions = options;
    return Uint8List.fromList(utf8.encode(texts[variant] ?? ''));
  }
}
