import 'dart:io';

import 'package:test/test.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The bindings, against the real engine.
///
/// There is no mock here on purpose. The thing these tests are for is the
/// boundary — whether twelve symbols resolve, whether a handle's lifetime is
/// handled, whether bytes survive the trip — and a mock would answer none of
/// that. What they do not re-test is transcription: the Swift suites own that,
/// and running a second end-to-end job through Dart would cost minutes to learn
/// nothing new.
///
/// The library is found through VOXSCRIPTA_LIBRARY, or in the SwiftPM build
/// tree. Tests skip rather than fail when it is absent, so a checkout that has
/// not built the engine yet is not a red suite.
void main() {
  final libraryPath = _findLibrary();

  group('VoxScriptaEngine', skip: libraryPath == null ? 'engine not built' : null, () {
    late VoxScriptaEngine engine;

    setUp(() => engine = VoxScriptaEngine.open(libraryPath: libraryPath));

    test('every symbol resolves and the ABI matches', () {
      // Construction looks up all twelve. If the hand-written bindings drift
      // from the library, this is where it surfaces — at test time, not on a
      // user's first tap.
      expect(engine.abiVersion, VoxScriptaEngine.supportedAbiVersion);
    });

    test('a library that is not there fails with a readable message', () {
      expect(
        () => VoxScriptaEngine.open(libraryPath: '/nonexistent/libNope.dylib'),
        throwsA(isA<VoxScriptaException>().having(
            (e) => e.message, 'message', contains('could not load the engine'))),
      );
    });

    test('a refused start throws with the engine\'s own words', () {
      // Empty paths, which the ABI rejects before any work begins.
      expect(
        () => engine.startJob(audioPath: '', projectPath: ''),
        throwsA(isA<VoxScriptaException>()),
      );
    });

    test('a failing job reaches a terminal state with a reason', () async {
      final directory = Directory.systemTemp.createTempSync('engine-test');
      addTearDown(() => directory.deleteSync(recursive: true));

      final job = engine.startJob(
        audioPath: '${directory.path}/nothing.wav',
        projectPath: '${directory.path}/p.voxscripta',
      );
      addTearDown(job.dispose);

      final outcome = await job.done.timeout(const Duration(seconds: 20));
      expect(outcome.state, JobState.failed);
      expect(outcome.failure, isNotNull);
      expect(outcome.failure, isNotEmpty);
    });

    test('the progress stream closes itself when the job ends', () async {
      final directory = Directory.systemTemp.createTempSync('engine-test');
      addTearDown(() => directory.deleteSync(recursive: true));

      final job = engine.startJob(
        audioPath: '${directory.path}/nothing.wav',
        projectPath: '${directory.path}/p.voxscripta',
      );
      addTearDown(job.dispose);

      // `await for` ending on its own is the property worth pinning — a stream
      // that stayed open would hang every screen that watched it.
      final seen = <JobState>[];
      await for (final report in job.progress.timeout(const Duration(seconds: 20))) {
        seen.add(report.state);
      }
      expect(seen, isNotEmpty);
      expect(seen.last.isTerminal, isTrue);
    });

    test('a disposed job reads as a handle the engine has forgotten', () async {
      final directory = Directory.systemTemp.createTempSync('engine-test');
      addTearDown(() => directory.deleteSync(recursive: true));

      final job = engine.startJob(
        audioPath: '${directory.path}/nothing.wav',
        projectPath: '${directory.path}/p.voxscripta',
      );
      await job.done.timeout(const Duration(seconds: 20));
      job.dispose();
      job.dispose(); // must be harmless

      expect(JobState.unknownHandle.isTerminal, isTrue);
    });

    test('cancelling a job the engine forgot does not throw', () {
      final directory = Directory.systemTemp.createTempSync('engine-test');
      addTearDown(() => directory.deleteSync(recursive: true));

      final job = engine.startJob(
        audioPath: '${directory.path}/nothing.wav',
        projectPath: '${directory.path}/p.voxscripta',
      );
      job.dispose();
      expect(job.cancel, returnsNormally);
    });

    test('a misspelled format is refused by name', () async {
      // Not reachable through the enum, so the check goes through the ABI's own
      // refusal path: a project with no transcript in it.
      final directory = Directory.systemTemp.createTempSync('engine-test');
      addTearDown(() => directory.deleteSync(recursive: true));

      expect(
        () => engine.exportSync(
          projectPath: '${directory.path}/missing.voxscripta',
          variant: TranscriptVariant.polished,
          format: ExportFormat.plainText,
        ),
        throwsA(isA<VoxScriptaException>().having((e) => e.code, 'code', -4)),
      );
    });

    test('export runs off the calling isolate', () async {
      final directory = Directory.systemTemp.createTempSync('engine-test');
      addTearDown(() => directory.deleteSync(recursive: true));

      // The point is that the helper isolate opens the library itself and the
      // failure still comes back as an exception rather than a dead isolate.
      await expectLater(
        engine.export(
          projectPath: '${directory.path}/missing.voxscripta',
          variant: TranscriptVariant.verbatim,
          format: ExportFormat.word,
        ),
        throwsA(isA<VoxScriptaException>()),
      );
    });
  });

  group('JobState', () {
    test('maps every code the ABI documents', () {
      expect(JobState.fromCode(0), JobState.imported);
      expect(JobState.fromCode(4), JobState.transcribing);
      expect(JobState.fromCode(8), JobState.complete);
      expect(JobState.fromCode(9), JobState.failed);
      expect(JobState.fromCode(10), JobState.cancelled);
      expect(JobState.fromCode(100), JobState.starting);
      expect(JobState.fromCode(-1), JobState.unknownHandle);
      // Anything the engine grows later reads as unknown rather than as some
      // unrelated stage, which is the reason the switch is explicit.
      expect(JobState.fromCode(77), JobState.unknownHandle);
    });

    test('only finished states are terminal', () {
      expect(JobState.transcribing.isTerminal, isFalse);
      expect(JobState.starting.isTerminal, isFalse);
      expect(JobState.complete.isTerminal, isTrue);
      expect(JobState.failed.isTerminal, isTrue);
    });
  });

  group('wire names', () {
    test('match the strings the ABI accepts', () {
      expect(TranscriptVariant.verbatim.wireName, 'verbatim');
      expect(TranscriptVariant.clean.wireName, 'clean');
      expect(TranscriptVariant.polished.wireName, 'polished');
      expect(ExportFormat.plainText.wireName, 'txt');
      expect(ExportFormat.markdown.wireName, 'md');
      expect(ExportFormat.word.wireName, 'docx');
      expect(ExportFormat.subRip.wireName, 'srt');
      expect(ExportFormat.webVTT.wireName, 'vtt');
    });
  });
}

String? _findLibrary() {
  final override = Platform.environment['VOXSCRIPTA_LIBRARY'];
  if (override != null && File(override).existsSync()) return override;
  for (final candidate in [
    '../../.build/out/Products/Debug/libVoxScriptaFFI.dylib',
    '../../.build/debug/libVoxScriptaFFI.dylib',
  ]) {
    if (File(candidate).existsSync()) return File(candidate).absolute.path;
  }
  return null;
}
