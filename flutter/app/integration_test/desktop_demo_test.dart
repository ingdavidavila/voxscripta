import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voxscripta/main.dart' as app;

/// A walk through the app that leaves a numbered frame on disk every few
/// hundred milliseconds, for turning into a screen recording.
///
/// The frames are painted from the app's own render tree, so they show exactly
/// what Flutter drew, and need no display server or window grab. They are not a
/// capture of the operating system's window.
///
///   VOXSCRIPTA_TEST_AUDIO=<jfk.wav> VOXSCRIPTA_WHISPER_MODEL=<ggml-base.bin>
///   VOXSCRIPTA_FRAME_DIR=<folder>
///   flutter test integration_test/desktop_demo_test.dart -d <windows|linux>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final audio = Platform.environment['VOXSCRIPTA_TEST_AUDIO'];
  final frames = Platform.environment['VOXSCRIPTA_FRAME_DIR'];
  var n = 0;

  Future<void> frame(WidgetTester tester) async {
    if (frames == null) return;
    await tester.runAsync(() async {
      final root = tester.binding.renderViews.first;
      final image = await (root.debugLayer as OffsetLayer)
          .toImage(Offset.zero & root.size, pixelRatio: 0.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      Directory(frames).createSync(recursive: true);
      final name = (n++).toString().padLeft(4, '0');
      File('$frames/$name.rgba').writeAsBytesSync(bytes!.buffer.asUint8List());
      File('$frames/size.txt').writeAsStringSync('${image.width} ${image.height}');
    });
  }

  /// Lets real time pass, so engine threads run, taking frames as it goes.
  Future<void> hold(WidgetTester tester, double seconds) async {
    final steps = (seconds * 4).round();
    for (var i = 0; i < steps; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)));
      await tester.pump(const Duration(milliseconds: 50));
      await frame(tester);
    }
  }

  testWidgets('a walk through the app', (tester) async {
    expect(audio, isNotNull, reason: 'set VOXSCRIPTA_TEST_AUDIO');
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await hold(tester, 1.5);

    await tester.tap(find.byTooltip('Open an audio file you already have.'));
    await tester.pumpAndSettle();
    await hold(tester, 1);
    await tester.enterText(find.byType(TextField), audio!);
    await hold(tester, 1.5);
    await tester.tap(find.text('Open').last);
    await tester.pump(const Duration(milliseconds: 300));

    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      await hold(tester, 0.5);
      if (find.textContaining('country').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    await hold(tester, 2);
    expect(find.textContaining('country'), findsWidgets);

    await tester.tap(find.text('Verbatim'));
    await tester.pumpAndSettle();
    await hold(tester, 1.5);
    await tester.tap(find.text('Clean'));
    await tester.pumpAndSettle();
    await hold(tester, 1.5);
  });
}
