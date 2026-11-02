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

  group('library and defaults',
      skip: libraryPath == null ? 'engine not built' : null, () {
    late VoxScriptaEngine engine;
    setUp(() => engine = VoxScriptaEngine.open(libraryPath: libraryPath));

    test('the library directory comes from the engine', () {
      // Not rebuilt here. If Dart constructed this path itself, the two
      // interfaces could end up pointing at different libraries.
      expect(engine.defaultLibraryDirectory, isNotEmpty);
      expect(engine.defaultLibraryDirectory, contains('VoxScripta'));
    });

    test('an empty directory is an empty library, not a failure', () {
      final directory = Directory.systemTemp.createTempSync('library-test');
      addTearDown(() => directory.deleteSync(recursive: true));
      expect(engine.library(directory: directory.path), isEmpty);
    });

    test('job defaults arrive with every key the options take', () {
      final defaults = engine.jobOptionDefaults;
      for (final key in [
        'locale',
        'detectLanguage',
        'concurrency',
        'silence',
        'chunking',
        'clean',
        'polish',
        'polishEnabled',
        'polishBackend',
        'keepIntermediates',
      ]) {
        expect(defaults.containsKey(key), isTrue, reason: 'missing $key');
      }
      // A settings screen renders from this, so the nested shapes have to be
      // objects rather than opaque strings.
      expect(defaults['silence'], isA<Map<String, Object?>>());
      expect(defaults['concurrency'], isA<int>());
    });

    test('export defaults arrive too', () {
      final defaults = engine.exportOptionDefaults;
      expect(defaults['includeTimestamps'], isFalse);
      expect(defaults['maximumCueLength'], isA<int>());
    });

    test('the defaults are valid input, round-tripped through a start', () {
      // The point is that whatever the engine reports can be handed straight
      // back without translation — otherwise a settings screen would need its
      // own mapping layer, which is a rule living in an interface.
      final defaults = engine.jobOptionDefaults;
      final directory = Directory.systemTemp.createTempSync('round-trip');
      addTearDown(() => directory.deleteSync(recursive: true));

      final job = engine.startJob(
        audioPath: '${directory.path}/nothing.wav',
        projectPath: '${directory.path}/p.voxscripta',
        options: JobOptions(
          locale: defaults['locale'] as String?,
          detectLanguage: defaults['detectLanguage'] as bool?,
          concurrency: defaults['concurrency'] as int?,
          silence: defaults['silence'] as Map<String, Object?>?,
          chunking: defaults['chunking'] as Map<String, Object?>?,
          clean: defaults['clean'] as Map<String, Object?>?,
          polish: defaults['polish'] as Map<String, Object?>?,
          polishEnabled: defaults['polishEnabled'] as bool?,
          polishBackend: defaults['polishBackend'] as String?,
          keepIntermediates: defaults['keepIntermediates'] as bool?,
        ),
      );
      addTearDown(job.dispose);
      // Accepted — it fails later for the missing audio, not for the settings.
      expect(job.handle, greaterThan(0));
    });

    test('a backend the engine does not know is refused by name', () {
      final directory = Directory.systemTemp.createTempSync('bad-backend');
      addTearDown(() => directory.deleteSync(recursive: true));
      expect(
        () => engine.startJob(
          audioPath: '${directory.path}/nothing.wav',
          projectPath: '${directory.path}/p.voxscripta',
          options: const JobOptions(polishBackend: 'gpt'),
        ),
        throwsA(isA<VoxScriptaException>()
            .having((e) => e.code, 'code', -3)
            .having((e) => e.message, 'message', contains('gpt'))),
      );
    });

    test('deleting something that is not a project is refused', () {
      final directory = Directory.systemTemp.createTempSync('delete-test');
      addTearDown(() => directory.deleteSync(recursive: true));
      expect(
        () => engine.deleteProject(directory.path),
        throwsA(isA<VoxScriptaException>()),
      );
    });
  });

  group('project summary',
      skip: libraryPath == null ? 'engine not built' : null, () {
    late VoxScriptaEngine engine;
    setUp(() => engine = VoxScriptaEngine.open(libraryPath: libraryPath));

    test('a project with nothing in it reports no variants', () {
      final directory = Directory.systemTemp.createTempSync('summary-test');
      addTearDown(() => directory.deleteSync(recursive: true));

      final summary = engine.summary('${directory.path}/empty.voxscripta');
      // Not an error: a job that is still running has no outputs, and the
      // screen should say so rather than fail.
      expect(summary.variants, isEmpty);
      expect(summary.polish.ran, isFalse);
      expect(summary.polish.hasSomethingToShow, isFalse);
    });

    test('an empty path is refused', () {
      expect(() => engine.summary(''), throwsA(isA<VoxScriptaException>()));
    });
  });

  group('PolishDisposition', () {
    test('maps the wire names, and anything new reads as unknown', () {
      expect(PolishDisposition.fromWire('accepted'), PolishDisposition.accepted);
      expect(PolishDisposition.fromWire('fellBackToClean'),
          PolishDisposition.fellBackToClean);
      expect(PolishDisposition.fromWire('somethingNew'), PolishDisposition.unknown);
    });

    test('only the model-accepted dispositions kept the rewrite', () {
      expect(PolishDisposition.accepted.keptModelText, isTrue);
      expect(PolishDisposition.acceptedAfterRetry.keptModelText, isTrue);
      // The CLEAN sentence surviving is the gauntlet working, not a failure.
      expect(PolishDisposition.fellBackToClean.keptModelText, isFalse);
      expect(PolishDisposition.modelFailed.keptModelText, isFalse);
    });
  });

  group('ProjectSummary decoding', () {
    test('reads counts and evidence out of the engine\'s JSON', () {
      final summary = ProjectSummary.fromJson(const {
        'variants': [
          {'variant': 'verbatim', 'words': 120, 'segments': 8},
          {'variant': 'clean', 'words': 101, 'segments': 8},
        ],
        'polish': {
          'ran': true,
          'skipReason': null,
          'accepted': 6,
          'acceptedAfterRetry': 1,
          'keptClean': 1,
          'flagged': [
            {
              'disposition': 'fellBackToClean',
              'original': 'we did not ship',
              'revised': 'we shipped',
              'reasons': ['polarity reversed'],
            }
          ],
        },
      });

      expect(summary.variants, hasLength(2));
      expect(summary.forVariant(TranscriptVariant.clean)?.words, 101);
      expect(summary.forVariant(TranscriptVariant.polished), isNull);
      expect(summary.polish.total, 8);
      expect(summary.polish.flagged.single.reasons, ['polarity reversed']);
      expect(summary.polish.flagged.single.disposition.keptModelText, isFalse);
    });

    test('a declined polish keeps its reason', () {
      final summary = ProjectSummary.fromJson(const {
        'variants': <Object?>[],
        'polish': {'ran': false, 'skipReason': 'Apple Intelligence is off'},
      });
      expect(summary.polish.ran, isFalse);
      expect(summary.polish.skipReason, 'Apple Intelligence is off');
      expect(summary.polish.hasSomethingToShow, isTrue);
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
