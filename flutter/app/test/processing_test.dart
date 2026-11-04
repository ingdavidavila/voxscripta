import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/processing/processing_model.dart';
import 'package:voxscripta/src/processing/processing_screen.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The processing screen.
///
/// §18 asks that this never look frozen, so what is pinned here is the parts
/// that make it readable while nothing visible is happening: the phase list
/// marking where the work is, the waveform appearing the moment analysis has
/// produced one, and a stopped job keeping the phase it stopped in rather than
/// pretending everything finished.
void main() {
  AudioFacts facts({
    int? regions,
    double? fraction,
    int? buckets,
    Duration duration = const Duration(minutes: 10),
    Duration? polish,
  }) =>
      AudioFacts(
        duration: duration,
        speechRegions: regions,
        speechFraction: fraction,
        waveformBuckets: buckets,
        polishEstimate: polish,
      );

  Future<_Stub> show(
    WidgetTester tester, {
    AudioFacts? audio,
    List<(double, double)>? waveform,
    String? startFailure,
  }) async {
    final stub = _Stub(
      audio: audio ?? facts(),
      waveform: waveform,
      startFailure: startFailure,
    );
    await tester.pumpWidget(MaterialApp(
      home: ProcessingScreen(
        model: ProcessingModel(
          source: stub,
          projectPath: '/library/Interview.voxscripta',
          displayName: 'Interview.m4a',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return stub;
  }

  testWidgets('every phase is listed, so the wait has a shape', (tester) async {
    await show(tester);
    for (final (_, label) in processingPhases) {
      expect(find.text(label), findsOne);
    }
  });

  testWidgets('before analysis the waveform says it is reading', (tester) async {
    await show(tester, audio: facts(buckets: null), waveform: null);
    expect(find.text('Reading audio…'), findsOne);
  });

  testWidgets('the waveform appears as soon as there is one', (tester) async {
    final stub = await show(tester,
        audio: facts(buckets: 400),
        waveform: const [(-0.5, 0.5), (-0.2, 0.9)]);
    // Fetched at the width asked for, so the engine downsamples once rather
    // than Dart discarding points it was handed.
    expect(stub.waveformRequests, isNotEmpty);
    expect(find.text('Reading audio…'), findsNothing);
  });

  testWidgets('the speech summary appears once silence detection has run',
      (tester) async {
    await show(tester, audio: facts(regions: 42, fraction: 0.63, buckets: 10));
    expect(find.textContaining('42 speech regions'), findsOne);
    expect(find.textContaining('63%'), findsOne);
  });

  testWidgets('a long polish is warned about before it starts', (tester) async {
    await show(tester,
        audio: facts(polish: const Duration(minutes: 23), buckets: 10));
    // Shown as soon as the duration is known, so a long job can be stopped
    // rather than mistaken for a hang an hour in.
    expect(find.textContaining('about 23 minutes'), findsOne);
  });

  testWidgets('a short polish is not warned about', (tester) async {
    await show(tester,
        audio: facts(polish: const Duration(seconds: 90), buckets: 10));
    expect(find.textContaining('Polishing will take'), findsNothing);
  });

  testWidgets('a job that will not start says so instead of spinning',
      (tester) async {
    await show(tester, startFailure: 'the audio file could not be found');
    expect(find.text('This job could not start'), findsOne);
    expect(find.textContaining('could not be found'), findsOne);
    // Nothing to stop, so nothing offers to.
    expect(find.text('Stop'), findsNothing);
  });

  testWidgets('the phase in progress is marked, and the ones before it done',
      (tester) async {
    final stub = await show(tester, audio: facts(buckets: 4));
    stub.emit(const JobProgress(
        state: JobState.transcribing, fraction: 0.4, detail: 'Transcribing'));
    // pump, not pumpAndSettle: the current phase shows a spinner and never
    // settles. Every earlier test here passes with pumpAndSettle only because
    // the job has not entered a phase yet — which is worth knowing before the
    // next one is written.
    //
    // Twice, because stream delivery is asynchronous: the first pump lets the
    // report reach the model, the second rebuilds with it.
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOne);
    // Three phases come before transcribing, and all three are ticked.
    expect(find.byIcon(Icons.check_circle), findsExactly(3));
  });

  testWidgets('a failure mid-job keeps the engine\'s words', (tester) async {
    final stub = await show(tester, audio: facts(buckets: 4));
    stub.emit(const JobProgress(
      state: JobState.failed,
      fraction: 0.4,
      detail: 'Transcribing',
      failure: 'no speech was detected in this recording',
    ));
    await tester.pumpAndSettle();

    expect(find.text('This job stopped'), findsOne);
    expect(find.textContaining('no speech was detected'), findsOne);
  });

  testWidgets('finishing is announced once, after the frame', (tester) async {
    var announced = 0;
    final stub = _Stub(audio: facts(buckets: 4));
    await tester.pumpWidget(MaterialApp(
      home: ProcessingScreen(
        model: ProcessingModel(
          source: stub,
          projectPath: '/p',
          displayName: 'p',
        ),
        onFinished: (_, _) => announced += 1,
      ),
    ));
    await tester.pumpAndSettle();

    stub.emit(const JobProgress(
        state: JobState.complete, fraction: 1, detail: 'Done'));
    await tester.pumpAndSettle();
    stub.emit(const JobProgress(
        state: JobState.complete, fraction: 1, detail: 'Done'));
    await tester.pumpAndSettle();

    // Once, not once per notification — otherwise the shell would push the
    // transcript screen repeatedly.
    expect(announced, 1);
  });
}

/// A source that hands out a job whose progress the test drives.
class _Stub implements ProcessingSource {
  _Stub({required this.audio, List<(double, double)>? waveform, this.startFailure})
      : waveformValue = waveform;

  final AudioFacts audio;
  final List<(double, double)>? waveformValue;
  final String? startFailure;
  final List<int> waveformRequests = [];

  final StreamController<JobProgress> _progress =
      StreamController<JobProgress>.broadcast();

  void emit(JobProgress report) => _progress.add(report);

  @override
  Job start({required String projectPath, String? audioPath, JobOptions? options}) {
    if (startFailure case final message?) throw VoxScriptaException(message);
    return _StubJob(_progress.stream);
  }

  @override
  ProjectSummary summary(String projectPath) => ProjectSummary(
        variants: const [],
        polish: const PolishReview(
          ran: false,
          skipReason: null,
          accepted: 0,
          acceptedAfterRetry: 0,
          keptClean: 0,
          flagged: [],
        ),
        audio: audio,
      );

  @override
  List<(double, double)>? waveform(String projectPath, {int buckets = 0}) {
    waveformRequests.add(buckets);
    return waveformValue;
  }
}

/// A Job whose stream the test owns.
class _StubJob implements Job {
  _StubJob(this._stream);

  final Stream<JobProgress> _stream;

  @override
  Stream<JobProgress> get progress => _stream;

  @override
  JobProgress get latest => const JobProgress(
      state: JobState.starting, fraction: 0, detail: '');

  @override
  Future<JobProgress> get done => _stream.firstWhere((r) => r.state.isTerminal);

  @override
  int get handle => 1;

  @override
  void cancel() {}

  @override
  void dispose() {}
}
