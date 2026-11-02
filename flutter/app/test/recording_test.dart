import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/recording/recording_model.dart';
import 'package:voxscripta/src/recording/recording_screen.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The recording screen.
///
/// The thing worth protecting here is the audio. A screen that binned a
/// recording because someone navigated away, or that said "recording" while
/// writing had stopped, would lose work that cannot be recovered — so those
/// are what the tests pin, alongside the clock and meter behaviour.
void main() {
  group('formatRecordingClock', () {
    test('the hour place appears only once there is an hour', () {
      // Matches MediaTime's elapsed formatting in the SwiftUI recorder: the
      // hour should not sit at zero for the first hour of every recording.
      expect(formatRecordingClock(const Duration(seconds: 7)), '0:07');
      expect(formatRecordingClock(const Duration(minutes: 3, seconds: 7)), '3:07');
      expect(formatRecordingClock(const Duration(minutes: 59, seconds: 59)), '59:59');
      expect(formatRecordingClock(const Duration(hours: 1)), '1:00:00');
      expect(
          formatRecordingClock(const Duration(hours: 2, minutes: 4, seconds: 9)),
          '2:04:09');
    });

    test('a part-second does not round the clock forwards', () {
      // Showing 0:08 at 7.6 seconds would make a recording look longer than it
      // is, which matters when the number is the only evidence.
      expect(formatRecordingClock(const Duration(milliseconds: 7600)), '0:07');
    });
  });

  group('RecordingModel', () {
    test('a device that will not open leaves the engine\'s reason', () {
      final model = RecordingModel(
          source: _Stub(startFailure: 'no microphone is available'))
        ..start();

      expect(model.isActive, isFalse);
      expect(model.startFailure, 'no microphone is available');
    });

    test('the meter keeps a bounded history', () async {
      final stub = _Stub();
      final model = RecordingModel(source: stub)..start();

      for (var index = 0; index < RecordingModel.meterHistory + 20; index += 1) {
        stub.emit(level: index / 100);
      }
      await Future<void>.delayed(Duration.zero);

      // Bounded, or a long recording would grow a list until it mattered.
      expect(model.levels.length, RecordingModel.meterHistory);
      // And the newest sample is last, because the meter scrolls leftwards.
      expect(model.levels.last, closeTo((RecordingModel.meterHistory + 19) / 100, 1e-9));
    });

    test('finishing reports the file and spends the handle', () {
      final stub = _Stub(
          result: const RecordingResult(
              path: '/recordings/Recording.m4a', duration: Duration(seconds: 12)));
      final model = RecordingModel(source: stub)..start();

      final result = model.finish();
      expect(result?.path, '/recordings/Recording.m4a');
      expect(model.isActive, isFalse);
      expect(stub.job?.finished, isTrue);
    });

    test('discarding deletes, and only from an explicit choice', () {
      final stub = _Stub();
      final model = RecordingModel(source: stub)..start();

      model.discard();
      expect(stub.job?.discarded, isTrue);
      expect(model.levels, isEmpty);
    });

    test('disposing finishes rather than discards', () {
      final stub = _Stub();
      RecordingModel(source: stub)
        ..start()
        ..dispose();

      // A screen going away must not destroy audio. §5 protects originals, and
      // a recording nobody chose to throw away is about to become one.
      expect(stub.job?.finished, isTrue);
      expect(stub.job?.discarded, isFalse);
    });
  });

  group('RecordingScreen', () {
    /// Two pumps after anything that goes through the progress stream: the
    /// first lets the report reach the model, the second rebuilds with it.
    /// Stream delivery is asynchronous, and one pump leaves the screen showing
    /// the state before the report — which is how the first version of these
    /// tests failed.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    Future<RecordingModel> show(WidgetTester tester, _Stub stub) async {
      final model = RecordingModel(source: stub);
      await tester.pumpWidget(
          MaterialApp(home: RecordingScreen(model: model)));
      await settle(tester);
      return model;
    }

    testWidgets('a microphone that will not open says why', (tester) async {
      await show(tester, _Stub(startFailure: 'the microphone did not start'));
      expect(find.text('The microphone could not be opened'), findsOne);
      expect(find.textContaining('did not start'), findsOne);
      // Nothing to finish or discard, so no transport is offered.
      expect(find.text('Finish'), findsNothing);
    });

    testWidgets('the clock and the privacy line are shown', (tester) async {
      final stub = _Stub();
      await show(tester, stub);
      stub.emit(elapsed: const Duration(minutes: 1, seconds: 5));
      await settle(tester);

      expect(find.text('1:05'), findsOne);
      expect(find.textContaining('never leaves this device'), findsOne);
    });

    testWidgets('writing stopping is reported without losing what is recorded',
        (tester) async {
      final stub = _Stub();
      await show(tester, stub);
      stub.emit(failure: 'the disk is full');
      await settle(tester);

      expect(find.text('Writing stopped'), findsOne);
      expect(find.textContaining('still on disk'), findsOne);
      // The transport stays usable: the audio before the failure is worth
      // keeping, so Finish must remain reachable.
      expect(find.text('Finish'), findsOne);
    });

    testWidgets('discarding asks first', (tester) async {
      final stub = _Stub();
      await show(tester, stub);
      stub.emit();
      await settle(tester);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.text('Discard this recording?'), findsOne);

      await tester.tap(find.text('Keep recording'));
      await tester.pumpAndSettle();
      expect(stub.job?.discarded, isFalse);
    });

    testWidgets('finishing hands the file on', (tester) async {
      final stub = _Stub(
          result: const RecordingResult(
              path: '/recordings/New.m4a', duration: Duration(seconds: 4)));
      RecordingResult? handed;
      final model = RecordingModel(source: stub);
      await tester.pumpWidget(MaterialApp(
        home: RecordingScreen(
          model: model,
          onFinished: (_, result) => handed = result,
        ),
      ));
      await settle(tester);
      stub.emit();
      await settle(tester);

      await tester.tap(find.text('Finish'));
      await tester.pump();
      expect(handed?.path, '/recordings/New.m4a');
    });
  });
}

class _Stub implements RecordingSource {
  _Stub({this.startFailure, this.result});

  final String? startFailure;
  final RecordingResult? result;
  _StubRecording? job;

  void emit({
    RecordingState state = RecordingState.recording,
    Duration elapsed = Duration.zero,
    double level = 0.4,
    String? failure,
  }) =>
      job?.emit(RecordingProgress(
        state: state,
        elapsed: elapsed,
        level: level,
        failure: failure,
      ));

  @override
  Recording start({String? destinationPath}) {
    if (startFailure case final message?) throw VoxScriptaException(message);
    return job = _StubRecording(result);
  }

  @override
  String get directory => '/recordings';
}

/// A Recording the test drives. Implements the surface rather than extending
/// it, since the real one owns a timer and a handle.
class _StubRecording implements Recording {
  _StubRecording(this._result);

  final RecordingResult? _result;
  final StreamController<RecordingProgress> _controller =
      StreamController<RecordingProgress>.broadcast();

  bool finished = false;
  bool discarded = false;
  RecordingProgress _latest = const RecordingProgress(
      state: RecordingState.idle, elapsed: Duration.zero, level: 0);

  void emit(RecordingProgress report) {
    _latest = report;
    _controller.add(report);
  }

  @override
  Stream<RecordingProgress> get progress => _controller.stream;

  @override
  RecordingProgress get latest => _latest;

  @override
  int get handle => 1;

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  RecordingResult? finish() {
    finished = true;
    return _result;
  }

  @override
  void discard() => discarded = true;
}
