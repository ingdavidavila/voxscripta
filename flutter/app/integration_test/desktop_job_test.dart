import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voxscripta/main.dart' as app;

/// The real app, on a real engine, from launch to a finished transcript.
///
/// Run with the audio and, where the model is not beside the executable, the
/// model named in the environment:
///
///   VOXSCRIPTA_TEST_AUDIO=C:\path\jfk.wav
///   VOXSCRIPTA_WHISPER_MODEL=C:\path\ggml-base.bin
///   VOXSCRIPTA_SHOT_DIR=C:\where\screenshots\go
///   flutter test integration_test/desktop_job_test.dart -d windows
///
/// Screenshots are taken by painting the app's own render tree to an image,
/// because a window grab returns blank for a GPU-drawn Flutter window.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final audio = Platform.environment['VOXSCRIPTA_TEST_AUDIO'];
  final shots = Platform.environment['VOXSCRIPTA_SHOT_DIR'];

  Future<void> shot(WidgetTester tester, String name) async {
    if (shots == null) return;
    await tester.runAsync(() async {
      final boundary = tester.binding.renderViews.first;
      final layer = boundary.debugLayer as OffsetLayer;
      final image = await layer.toImage(Offset.zero & boundary.size);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shots).createSync(recursive: true);
      File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  testWidgets('import, transcribe and read a transcript', (tester) async {
    expect(audio, isNotNull, reason: 'set VOXSCRIPTA_TEST_AUDIO');
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await shot(tester, '1-library');

    await tester.tap(find.byTooltip('Open an audio file you already have.'));
    await tester.pumpAndSettle();
    await shot(tester, '2-import');

    await tester.enterText(find.byType(TextField), audio!);
    await tester.tap(find.text('Open').last);
    await tester.pump(const Duration(seconds: 1));
    await shot(tester, '3-processing');

    // The job runs on the engine's own threads; wait for the transcript view.
    final deadline = DateTime.now().add(const Duration(minutes: 8));
    while (DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
      await tester.pump(const Duration(milliseconds: 200));
      if (find.textContaining('country').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    await shot(tester, '4-transcript');
    expect(find.textContaining('country'), findsWidgets,
        reason: 'the transcript of jfk.wav mentions "your country"');
  });
}
