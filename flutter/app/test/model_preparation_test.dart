import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/model_preparation.dart';
import 'package:voxscripta/src/processing/processing_model.dart';
import 'package:voxscripta/src/processing/processing_screen.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// Waiting for the speech model before a job.
///
/// What matters is that a job never starts against a model that is half copied,
/// that a full disk is reported as a full disk instead of as a failed
/// transcription minutes later, and that nothing starts for a screen that has
/// already gone.
class _Preparation implements ModelPreparation {
  final Completer<ModelProblem?> _done = Completer<ModelProblem?>();
  void Function(double?)? _onProgress;

  void progress(double? fraction) => _onProgress?.call(fraction);
  void finish([ModelProblem? problem]) => _done.complete(problem);

  @override
  Future<ModelProblem?> prepare({void Function(double? fraction)? onProgress}) {
    _onProgress = onProgress;
    return _done.future;
  }
}

class _Source implements ProcessingSource {
  int started = 0;

  @override
  Job start({required String projectPath, String? audioPath, JobOptions? options}) {
    started += 1;
    throw VoxScriptaException('stub engine reached');
  }

  @override
  ProjectSummary summary(String projectPath) =>
      throw VoxScriptaException('no summary');

  @override
  List<(double, double)>? waveform(String projectPath, {int buckets = 0}) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the channel', () {
    const channel = MethodChannel(ChannelModelPreparation.channelName);

    void answer(Future<Object?> Function(MethodCall)? handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    tearDown(() => answer(null));

    for (final state in ['ready', 'absent']) {
      test('"$state" lets the job go ahead', () async {
        answer((call) async => {'state': state});
        expect(await const ChannelModelPreparation().prepare(), isNull);
      });
    }

    test('a full disk comes back as a reason with the amount', () async {
      answer((call) async =>
          {'state': 'failed', 'error': 'no_space', 'neededMb': 540});
      final problem = await const ChannelModelPreparation().prepare();
      expect(problem?.kind, ModelProblemKind.noSpace);
      expect(problem?.megabytes, 540);
    });

    test('a model that could not be put in place is its own reason', () async {
      answer((call) async => {'state': 'failed', 'error': 'not_in_place'});
      expect((await const ChannelModelPreparation().prepare())?.kind,
          ModelProblemKind.notInPlace);
    });

    test('an unknown failure still says something went wrong', () async {
      answer((call) async => {'state': 'failed', 'detail': 'disk on fire'});
      final problem = await const ChannelModelPreparation().prepare();
      expect(problem?.kind, ModelProblemKind.copyFailed);
      expect(problem?.detail, 'disk on fire');
    });

    test('a platform error is reported rather than thrown', () async {
      answer((call) async => throw PlatformException(code: 'boom', message: 'no'));
      final problem = await const ChannelModelPreparation().prepare();
      expect(problem?.kind, ModelProblemKind.copyFailed);
      expect(problem?.detail, 'no');
    });

    test('no host at all means nothing to prepare', () async {
      answer(null);
      expect(await const ChannelModelPreparation().prepare(), isNull);
    });

    test('progress is the fraction copied, and unknown when the size is', () async {
      final fractions = <double?>[];
      final gate = Completer<void>();
      answer((call) async {
        if (call.method == 'status') {
          return {'state': 'copying', 'copied': 250, 'total': 1000};
        }
        await gate.future;
        return {'state': 'ready'};
      });
      final result = const ChannelModelPreparation(
              pollInterval: Duration(milliseconds: 10))
          .prepare(onProgress: fractions.add);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      gate.complete();
      expect(await result, isNull);
      expect(fractions, isNotEmpty);
      expect(fractions.first, 0.25);
    });
  });

  group('ProcessingModel', () {
    ProcessingModel build(_Source source, ModelPreparation? preparation) =>
        ProcessingModel(
          source: source,
          projectPath: '/p',
          displayName: 'p',
          audioPath: '/a.wav',
          preparation: preparation,
        );

    test('does not start the job until the model is ready', () async {
      final source = _Source();
      final preparation = _Preparation();
      final model = build(source, preparation);

      final started = model.start();
      expect(model.isPreparingModel, isTrue);
      expect(source.started, 0);

      preparation.finish();
      await started;
      expect(model.isPreparingModel, isFalse);
      expect(source.started, 1);
    });

    test('a problem stops it before the engine is reached', () async {
      final source = _Source();
      final preparation = _Preparation();
      final model = build(source, preparation);

      final started = model.start();
      preparation.finish(
          const ModelProblem(ModelProblemKind.noSpace, megabytes: 540));
      await started;

      expect(source.started, 0);
      expect(model.modelProblem?.kind, ModelProblemKind.noSpace);
      expect(model.startFailure, isNull);
    });

    test('progress reaches the model', () async {
      final preparation = _Preparation();
      final model = build(_Source(), preparation);

      unawaited(model.start());
      preparation.progress(0.4);
      expect(model.modelFraction, 0.4);
      preparation.finish();
    });

    test('a screen that went away does not start a job', () async {
      final source = _Source();
      final preparation = _Preparation();
      final model = build(source, preparation);

      final started = model.start();
      model.dispose();
      preparation.finish();
      await started;

      expect(source.started, 0);
    });

    test('with nothing to prepare it starts at once, as before', () {
      final source = _Source();
      unawaited(build(source, null).start());
      expect(source.started, 1);
    });
  });

  testWidgets('the screen says what it is waiting for', (tester) async {
    final preparation = _Preparation();
    final model = ProcessingModel(
      source: _Source(),
      projectPath: '/p',
      displayName: 'p',
      audioPath: '/a.wav',
      preparation: preparation,
    );
    await tester.pumpWidget(MaterialApp(home: ProcessingScreen(model: model)));
    await tester.pump();

    expect(find.text('Preparing the speech model'), findsOne);
    expect(find.textContaining('uses no network'), findsOne);

    preparation.finish();
    await tester.pump();
    await tester.pump();
    expect(find.text('Preparing the speech model'), findsNothing);
  });
}
