import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/library/library_model.dart';
import 'package:voxscripta/src/platform_traits.dart';
import 'package:voxscripta/src/library/library_screen.dart';
import 'package:voxscripta/src/auth/auth_service.dart';
import 'package:voxscripta/src/auth/sign_in_screen.dart';
import 'package:voxscripta/src/auth/sign_up_screen.dart';
import 'package:voxscripta/src/paywall/paywall_screen.dart';
import 'package:voxscripta/src/paywall/subscription_service.dart';
import 'package:voxscripta/src/processing/processing_model.dart';
import 'package:voxscripta/src/recording/recording_model.dart';
import 'package:voxscripta/src/recording/recording_screen.dart';
import 'package:voxscripta/src/processing/processing_screen.dart';
import 'package:voxscripta/src/settings/settings_model.dart';
import 'package:voxscripta/src/settings/settings_screen.dart';
import 'package:voxscripta/src/transcript/transcript_model.dart';
import 'package:voxscripta/src/transcript/transcript_screen.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// Renders the screens to PNG, so they can be looked at without a machine to
/// run them on.
///
/// Not a golden *test* in the usual sense — nothing here asserts that pixels
/// match a reference, because the only platform available to render on is the
/// one platform this app will never ship to. It is a preview: `flutter test
/// --update-goldens test/preview_test.dart` writes the images and they are
/// reviewed by eye.
///
/// One substitution to know about when looking at them. Flutter's test
/// environment has no real fonts — every glyph renders as a filled rectangle —
/// so a system font is loaded here. The shipped app uses each platform's own
/// default: Roboto on Android and Linux, Segoe UI on Windows. So the shapes,
/// spacing and colour are the app's; the letterforms are not.
void main() {
  setUpAll(() async {
    await _loadFont('Preview', const {
      '/System/Library/Fonts/Supplemental/Arial.ttf': FontWeight.normal,
      '/System/Library/Fonts/Supplemental/Arial Bold.ttf': FontWeight.bold,
    });
    // Icons are a font too, and without it every icon renders as a filled
    // rectangle — which looks like a design decision rather than a missing
    // asset. Flutter ships this one in its own cache.
    final home = Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/development/flutter';
    await _loadFont('MaterialIcons', {
      '$home/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf':
          FontWeight.normal,
    });
  });

  final now = DateTime(2026, 11, 1, 16, 30);

  ProjectEntry entry(String name, Duration length, Duration ago) => ProjectEntry(
        id: name,
        path: '/Users/you/Library/Application Support/VoxScripta/Projects/'
            '$name.voxscripta',
        displayName: name,
        duration: length,
        state: JobState.complete,
        modifiedAt: now.subtract(ago),
      );

  final populated = [
    entry('Board meeting 2026-10-28.m4a', const Duration(hours: 1, minutes: 12, seconds: 4, milliseconds: 120), const Duration(minutes: 6)),
    entry('Entrevista con Marta.wav', const Duration(minutes: 47, seconds: 31, milliseconds: 880), const Duration(hours: 3)),
    entry('Voice memo 014.m4a', const Duration(minutes: 3, seconds: 7, milliseconds: 250), const Duration(days: 1)),
    entry('Site visit notes.mp3', const Duration(minutes: 18, seconds: 2, milliseconds: 5), const Duration(days: 4)),
    entry('Lecture — portable DSP.m4a', const Duration(hours: 2, minutes: 4, seconds: 56, milliseconds: 700), const Duration(days: 12)),
  ];

  Future<void> render(
    WidgetTester tester, {
    required String name,
    required Size size,
    required Brightness brightness,
    required List<ProjectEntry> projects,
    required bool pointer,
  }) async {
    // The preview renders on macOS, so without this the phone shots would show
    // desktop affordances — a hover tooltip and no overflow button — which is
    // the wrong platform's behaviour at the right size.
    PlatformTraits.debugPointerOverride = pointer;
    addTearDown(() => PlatformTraits.debugPointerOverride = null);

    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3B6EA5),
          brightness: brightness,
        ),
        visualDensity:
            size.width > 700 ? VisualDensity.compact : VisualDensity.standard,
        fontFamily: 'Preview',
        useMaterial3: true,
      ),
      home: LibraryScreen(
        model: LibraryModel(_PreviewSource(projects)),
        // Wired, because the preview should look like the shipped app: the
        // toolbar and the empty state both change when they are not.
        openProject: (_, _) {},
        openSettings: (_) {},
        openRecorder: (_) {},
        openImporter: (_) {},
      ),
    ));
    await tester.pumpAndSettle();
    await expectLater(find.byType(LibraryScreen), matchesGoldenFile('previews/$name.png'));
  }

  Future<void> renderTranscript(
    WidgetTester tester, {
    required String name,
    required Size size,
    required Brightness brightness,
    required bool pointer,
    required bool showReview,
  }) async {
    PlatformTraits.debugPointerOverride = pointer;
    addTearDown(() => PlatformTraits.debugPointerOverride = null);
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final model = TranscriptModel(
      source: const _PreviewTranscripts(),
      projectPath: '/library/Board meeting.voxscripta',
      displayName: 'Board meeting 2026-10-28.m4a',
    );

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF3B6EA5), brightness: brightness),
        visualDensity:
            size.width > 700 ? VisualDensity.compact : VisualDensity.standard,
        fontFamily: 'Preview',
        useMaterial3: true,
      ),
      home: TranscriptScreen(model: model),
    ));
    await tester.pumpAndSettle();
    if (showReview) {
      model.toggleReview();
      await tester.pumpAndSettle();
    }
    await expectLater(
        find.byType(TranscriptScreen), matchesGoldenFile('previews/$name.png'));
  }

  Future<void> renderSettings(
    WidgetTester tester, {
    required String name,
    required Size size,
    required bool pointer,
  }) async {
    PlatformTraits.debugPointerOverride = pointer;
    addTearDown(() => PlatformTraits.debugPointerOverride = null);
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6EA5)),
        visualDensity:
            size.width > 700 ? VisualDensity.compact : VisualDensity.standard,
        fontFamily: 'Preview',
        useMaterial3: true,
      ),
      home: SettingsScreen(model: SettingsModel(source: const _PreviewSettings())),
    ));
    await tester.pumpAndSettle();
    await expectLater(
        find.byType(SettingsScreen), matchesGoldenFile('previews/$name.png'));
  }

  Future<void> renderAuth(
    WidgetTester tester, {
    required String name,
    required Widget home,
    required Size size,
  }) async {
    PlatformTraits.debugPointerOverride = size.width > 700;
    addTearDown(() => PlatformTraits.debugPointerOverride = null);
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6EA5)),
        fontFamily: 'Preview',
        useMaterial3: true,
      ),
      home: home,
    ));
    await tester.pumpAndSettle();
    await expectLater(find.byType(Scaffold).first,
        matchesGoldenFile('previews/$name.png'));
  }

  testWidgets('paywall, phone', (tester) async {
    await renderAuth(tester,
        name: 'paywall',
        size: const Size(400, 1000),
        home: PaywallScreen(
          entitlement: const Entitlement(
            state: EntitlementState.trialExpired,
            allowsNewWork: false,
            shouldOfferSubscription: true,
            trialDays: 3,
          ),
          service: _PreviewStore(),
          onOpenLink: (_) {},
        ));
  });

  testWidgets('sign in, phone', (tester) async {
    await renderAuth(tester,
        name: 'auth-sign-in',
        size: const Size(400, 860),
        home: SignInScreen(auth: _PreviewAuth(), onSkip: (_) {}));
  });

  testWidgets('sign up, phone', (tester) async {
    await renderAuth(tester,
        name: 'auth-sign-up',
        size: const Size(400, 900),
        home: SignUpScreen(
          auth: _PreviewAuth(),
          emailCheck: (s) => s.contains('@'),
          rules: _previewRules,
        ));
  });

  testWidgets('recording, phone', (tester) async {
    PlatformTraits.debugPointerOverride = false;
    addTearDown(() => PlatformTraits.debugPointerOverride = null);
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final stub = _PreviewRecording();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6EA5)),
        fontFamily: 'Preview',
        useMaterial3: true,
      ),
      home: RecordingScreen(model: RecordingModel(source: stub)),
    ));
    await tester.pump();
    await tester.pump();
    // A plausible run of levels, so the meter shows what it really shows.
    for (var index = 0; index < RecordingModel.meterHistory; index += 1) {
      stub.emit(index);
      await tester.pump();
      await tester.pump();
    }
    await expectLater(find.byType(RecordingScreen),
        matchesGoldenFile('previews/recording-phone.png'));
  });

  testWidgets('processing, desktop', (tester) async {
    PlatformTraits.debugPointerOverride = true;
    addTearDown(() => PlatformTraits.debugPointerOverride = null);
    tester.view
      ..physicalSize = const Size(900, 640)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B6EA5)),
        visualDensity: VisualDensity.compact,
        fontFamily: 'Preview',
        useMaterial3: true,
      ),
      home: ProcessingScreen(
        model: ProcessingModel(
          source: _PreviewJob(),
          projectPath: '/library/Board meeting.voxscripta',
          displayName: 'Board meeting 2026-10-28.m4a',
        ),
      ),
    ));
    // pump, not pumpAndSettle: the current phase shows a spinner, which never
    // settles, so pumpAndSettle waits for a quiet frame that will not come.
    // Two pumps are enough for the stream's first report to arrive and the
    // facts to be read.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await expectLater(find.byType(ProcessingScreen),
        matchesGoldenFile('previews/processing-desktop.png'));
  });

  testWidgets('settings, desktop', (tester) async {
    await renderSettings(tester,
        name: 'settings-desktop', size: const Size(900, 1500), pointer: true);
  });

  testWidgets('desktop, with recordings', (tester) async {
    await render(tester,
        name: 'library-desktop-light',
        pointer: true,
        size: const Size(1000, 640),
        brightness: Brightness.light,
        projects: populated);
  });

  testWidgets('desktop, dark', (tester) async {
    await render(tester,
        name: 'library-desktop-dark',
        pointer: true,
        size: const Size(1000, 640),
        brightness: Brightness.dark,
        projects: populated);
  });

  testWidgets('desktop, empty', (tester) async {
    await render(tester,
        name: 'library-desktop-empty',
        pointer: true,
        size: const Size(1000, 640),
        brightness: Brightness.light,
        projects: const []);
  });

  testWidgets('phone, with recordings', (tester) async {
    await render(tester,
        name: 'library-phone-light',
        pointer: false,
        size: const Size(400, 800),
        brightness: Brightness.light,
        projects: populated);
  });

  testWidgets('transcript, desktop with review', (tester) async {
    await renderTranscript(tester,
        name: 'transcript-desktop-review',
        size: const Size(1100, 700),
        brightness: Brightness.light,
        pointer: true,
        showReview: true);
  });

  testWidgets('transcript, phone', (tester) async {
    await renderTranscript(tester,
        name: 'transcript-phone',
        size: const Size(400, 800),
        brightness: Brightness.light,
        pointer: false,
        showReview: false);
  });

  testWidgets('phone, empty', (tester) async {
    await render(tester,
        name: 'library-phone-empty',
        pointer: false,
        size: const Size(400, 800),
        brightness: Brightness.light,
        projects: const []);
  });
}

/// Loads real letterforms into the test's font manager.
Future<void> _loadFont(String family, Map<String, FontWeight> files) async {
  final loader = FontLoader(family);
  var loaded = 0;
  for (final path in files.keys) {
    final file = File(path);
    if (!file.existsSync()) continue;
    loader.addFont(Future.value(file.readAsBytesSync().buffer.asByteData()));
    loaded += 1;
  }
  if (loaded == 0) {
    // Said out loud rather than silently producing a page of black rectangles
    // and letting someone think that is the design.
    // ignore: avoid_print
    print('WARNING: no preview font found; text will render as boxes');
    return;
  }
  await loader.load();
}

class _PreviewSource implements LibrarySource {
  const _PreviewSource(this.projects);

  final List<ProjectEntry> projects;

  @override
  String get directory =>
      '/Users/you/Library/Application Support/VoxScripta/Projects';

  @override
  List<ProjectEntry> list() => projects;

  @override
  String? delete(String path) => null;
}

/// Sample outputs for the transcript previews.
class _PreviewTranscripts implements TranscriptSource {
  const _PreviewTranscripts();

  @override
  ProjectSummary summary(String projectPath) => const ProjectSummary(
        variants: [
          VariantSummary(
              variant: TranscriptVariant.verbatim, words: 1841, segments: 96),
          VariantSummary(
              variant: TranscriptVariant.clean, words: 1702, segments: 96),
          VariantSummary(
              variant: TranscriptVariant.polished, words: 1655, segments: 94),
        ],
        polish: PolishReview(
          ran: true,
          skipReason: null,
          accepted: 91,
          acceptedAfterRetry: 2,
          keptClean: 1,
          flagged: [
            FlaggedSentence(
              disposition: PolishDisposition.fellBackToClean,
              original: 'We did not approve the Q4 budget at that meeting.',
              revised: 'We approved the Q4 budget at that meeting.',
              reasons: ['polarity reversed: negation dropped'],
            ),
            FlaggedSentence(
              disposition: PolishDisposition.acceptedAfterRetry,
              original: 'so the the headcount plan is, um, forty two roles',
              revised: 'So the headcount plan is forty-two roles.',
              reasons: ['numeric conservation: 42 preserved on retry'],
            ),
          ],
        ),
      );

  @override
  Future<Uint8List> export({
    required String projectPath,
    required TranscriptVariant variant,
    required ExportFormat format,
    ExportOptions? options,
  }) async =>
      Uint8List.fromList(utf8.encode(switch (variant) {
        TranscriptVariant.verbatim =>
          'So, um, the first item is the, the Q4 budget. We did not approve '
              'the Q4 budget at that meeting, uh, because the headcount plan '
              'was still open.\n\n'
              'Right. So the the headcount plan is, um, forty two roles, and '
              'that was, that was the sticking point.',
        TranscriptVariant.clean =>
          'The first item is the Q4 budget. We did not approve the Q4 budget '
              'at that meeting, because the headcount plan was still open.\n\n'
              'So the headcount plan is forty two roles, and that was the '
              'sticking point.',
        TranscriptVariant.polished =>
          'The first item was the Q4 budget. We did not approve it at that '
              'meeting, because the headcount plan was still open.\n\n'
              'The headcount plan is forty-two roles, and that was the '
              'sticking point.',
      }));
}

/// Engine answers for the settings preview.
class _PreviewSettings implements SettingsSource {
  const _PreviewSettings();

  @override
  Map<String, Object?> get jobDefaults => const {
        'locale': 'en-US',
        'detectLanguage': true,
        'concurrency': 4,
        'keepIntermediates': false,
        'polishEnabled': true,
        'polishBackend': 'automatic',
        'silence': {'marginDB': 6.0, 'minSilenceDuration': 0.5, 'padTrail': 0.2},
        'chunking': {'maxDuration': 300.0},
        'clean': {
          'removeFillers': true,
          'collapseRepetitions': true,
          'dropLowConfidence': true,
        },
      };

  @override
  Capabilities capabilities() => const Capabilities(
        locales: [
          LocaleOption(
            identifier: 'en-US',
            displayName: 'English (United States)',
            hasTextSupport: true,
            polishValidated: true,
          ),
          LocaleOption(
            identifier: 'es-ES',
            displayName: 'Spanish (Spain)',
            hasTextSupport: true,
            polishValidated: true,
          ),
        ],
        polish: PolishCapability(
          systemModelAvailable: true,
          bundledModel: 'Qwen2.5-1.5B-Instruct-4bit (qwen2)',
          effective: 'Apple on-device model',
          unavailableReason: null,
        ),
      );

  @override
  String get libraryDirectory =>
      '/Users/you/Library/Application Support/VoxScripta/Projects';
}

/// A job frozen mid-transcription, for the preview.
class _PreviewJob implements ProcessingSource {
  @override
  Job start({required String projectPath, String? audioPath, JobOptions? options}) =>
      _FrozenJob();

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
        audio: AudioFacts(
          duration: const Duration(minutes: 72),
          speechRegions: 148,
          speechFraction: 0.71,
          waveformBuckets: 2000,
          polishEstimate: const Duration(minutes: 101),
          speechSpans: _previewSpeechSpans,
        ),
      );

  @override
  List<(double, double)>? waveform(String projectPath, {int buckets = 0}) {
    // Derived from the same spans the screen shades, so the drawing is
    // coherent. The first version generated the two from different formulas
    // and the shading landed in the gaps between the bursts — which is
    // exactly the kind of thing a preview exists to catch.
    final count = buckets == 0 ? 600 : buckets;
    final seconds = 72 * 60.0;
    return [
      for (var index = 0; index < count; index += 1)
        _bucket((index + 0.5) / count * seconds, index),
    ];
  }

  static (double, double) _bucket(double at, int index) {
    final speaking = _previewSpeechSpans.any((s) => at >= s.$1 && at <= s.$2);
    // Two rates rather than one: a slow swell for the shape of a phrase and a
    // fast grain for syllables. A single frequency gave near-constant
    // amplitude, so every burst drew as a solid block.
    final swell = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(index * 0.11)).abs();
    final grain = (0.2 + 0.8 * math.sin(index * 1.9).abs()) *
        (0.4 + 0.6 * math.sin(index * 0.61).abs());
    final amplitude = speaking ? (0.12 + 0.85 * grain) * swell : 0.015;
    return (-amplitude, amplitude);
  }
}

/// Reports one fixed state, so the preview is a still of a running job.
class _FrozenJob implements Job {
  @override
  Stream<JobProgress> get progress => Stream<JobProgress>.value(latest);

  @override
  JobProgress get latest => const JobProgress(
        state: JobState.transcribing,
        fraction: 0.46,
        detail: 'Transcribing — segment 9 of 21',
      );

  @override
  Future<JobProgress> get done => Completer<JobProgress>().future;

  @override
  int get handle => 1;

  @override
  void cancel() {}

  @override
  void dispose() {}
}

/// Speech spans matching the preview waveform's bursts, so the shading lines
/// up with the audio instead of being shaded at one end.
final _previewSpeechSpans = <(double, double)>[
  for (var index = 0; index < 11; index += 1)
    (
      index * 72 * 60 / 11 + 20,
      index * 72 * 60 / 11 + 72 * 60 / 11 - 60,
    ),
];

/// A recording the preview drives through a plausible level history.
class _PreviewRecording implements RecordingSource {
  _PreviewJobRecording? _job;

  void emit(int index) {
    final swell = 0.45 + 0.5 * math.sin(index * 0.19).abs();
    final grain = 0.3 + 0.7 * math.sin(index * 1.7).abs();
    _job?.emit(RecordingProgress(
      state: RecordingState.recording,
      elapsed: Duration(milliseconds: 47_000 + index * 50),
      level: (swell * grain).clamp(0.05, 1.0),
    ));
  }

  @override
  Recording start({String? destinationPath}) =>
      _job = _PreviewJobRecording();

  @override
  String get directory =>
      '/Users/you/Library/Application Support/VoxScripta/Recordings';
}

class _PreviewJobRecording implements Recording {
  final StreamController<RecordingProgress> _controller =
      StreamController<RecordingProgress>.broadcast();

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
  RecordingResult? finish() => null;

  @override
  void discard() {}
}

/// Password rules for the preview, in the engine's shape, part-way typed so
/// the checklist shows both states.
List<PasswordRule> _previewRules(String password) => [
      PasswordRule(
          id: 'length', demand: 'At least 8 characters',
          satisfied: password.length >= 8),
      PasswordRule(
          id: 'uppercase', demand: 'One capital letter',
          satisfied: password.contains(RegExp('[A-Z]'))),
      PasswordRule(
          id: 'number', demand: 'One number',
          satisfied: password.contains(RegExp('[0-9]'))),
      PasswordRule(
          id: 'special', demand: 'One symbol, such as ! ? # or &',
          satisfied: password.contains(RegExp(r'[^A-Za-z0-9\s]'))),
    ];

/// An account service that is not connected, which is the truthful state.
class _PreviewAuth implements AuthService {
  @override
  AuthUser? get currentUser => null;
  @override
  Stream<AuthUser?> get changes => const Stream<AuthUser?>.empty();
  @override
  bool get supportsApple => true;
  @override
  bool get supportsGoogle => true;
  @override
  Future<AuthUser> signInWithApple() async => throw const AuthException('x');
  @override
  Future<AuthUser> signInWithGoogle() async => throw const AuthException('x');
  @override
  Future<AuthUser> signInWithPassword({
    required String email, required String password,
  }) async => throw const AuthException('x');
  @override
  Future<AuthUser> signUp({
    required String email, required String password,
  }) async => throw const AuthException('x');
  @override
  Future<void> sendPasswordReset(String email) async {}
  @override
  Future<void> signOut() async {}
  @override
  Future<void> deleteAccount() async {}
}

/// A store with plausible prices, for the preview only.
class _PreviewStore implements SubscriptionService {
  @override
  Future<List<SubscriptionProduct>> products() async => const [
        SubscriptionProduct(
          id: 'voxscripta.monthly',
          period: BillingPeriod.monthly,
          title: 'Monthly',
          price: '\u00a33.99',
          priceDetail: 'per month',
        ),
        SubscriptionProduct(
          id: 'voxscripta.yearly',
          period: BillingPeriod.yearly,
          title: 'Yearly',
          price: '\u00a329.99',
          priceDetail: 'per year \u2014 \u00a32.50 a month',
          savingNote: 'Save 37%',
        ),
      ];

  @override
  Future<void> purchase(SubscriptionProduct product) async {}
  @override
  Future<void> restore() async {}
  @override
  Uri? get managementPage => null;
  @override
  Uri get termsOfUse => Uri.parse('https://example.com/terms');
  @override
  Uri get privacyPolicy => Uri.parse('https://example.com/privacy');
}
