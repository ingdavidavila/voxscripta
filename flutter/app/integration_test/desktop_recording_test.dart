import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:voxscripta/main.dart' as app;

/// The recording screen on a real engine and whatever input device the machine
/// has. With a silent or virtual device this shows the silent-input card; with
/// a real microphone it shows a moving meter. Run like desktop_job_test.dart,
/// needing only VOXSCRIPTA_SHOT_DIR.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final shots = Platform.environment['VOXSCRIPTA_SHOT_DIR'];

  Future<void> shot(WidgetTester tester, String name) async {
    if (shots == null) return;
    await tester.runAsync(() async {
      final root = tester.binding.renderViews.first;
      final image = await (root.debugLayer as OffsetLayer)
          .toImage(Offset.zero & root.size);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      Directory(shots).createSync(recursive: true);
      File('$shots/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  Future<void> wait(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds * 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets('record for a few seconds and finish', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.tap(find.byTooltip('Record something now.'));
    await tester.pump(const Duration(milliseconds: 500));
    await shot(tester, 'rec-1-opening');
    await wait(tester, 3);
    await shot(tester, 'rec-2-recording');
    await wait(tester, 8);
    await shot(tester, 'rec-3-after-11s');
    expect(find.text('Recording…'), findsWidgets);

    await tester.tap(find.text('Finish'));
    await tester.pump(const Duration(seconds: 1));
    await wait(tester, 4);
    await shot(tester, 'rec-4-finished');
  });
}
