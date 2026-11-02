import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/library/library_model.dart';
import 'package:voxscripta/src/platform_traits.dart';
import 'package:voxscripta/src/library/library_screen.dart';
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
      home: LibraryScreen(model: LibraryModel(_PreviewSource(projects))),
    ));
    await tester.pumpAndSettle();
    await expectLater(find.byType(LibraryScreen), matchesGoldenFile('previews/$name.png'));
  }

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
