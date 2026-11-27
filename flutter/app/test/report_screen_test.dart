import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/l10n/app_localizations.dart';
import 'package:voxscripta/src/report/report_screen.dart';
import 'package:voxscripta/src/transcript/file_saver.dart';

/// What matters here is order: the person sees the whole report before
/// anything leaves, and nothing leaves unless they press something.
void main() {
  const report = 'version: 0.3.0\nplatform: test\nlast error: <path>.wav';

  Future<void> show(
    WidgetTester tester, {
    String? text = report,
    _Sharer? sharer,
    _Saver? saver,
    Locale? locale,
  }) async {
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ReportScreen(report: text, sharer: sharer, saver: saver),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the whole report is on screen and nothing has left',
      (tester) async {
    final sharer = _Sharer();
    final saver = _Saver();
    await show(tester, sharer: sharer, saver: saver);

    expect(find.text(report), findsOne);
    expect(sharer.shared, isEmpty);
    expect(saver.saved, isNull);
  });

  testWidgets('sharing hands over exactly what was shown', (tester) async {
    final sharer = _Sharer();
    await show(tester, sharer: sharer, saver: _Saver());
    await tester.tap(find.text('Share…'));
    await tester.pumpAndSettle();
    expect(sharer.shared, [report]);
  });

  testWidgets('saving writes exactly what was shown', (tester) async {
    final saver = _Saver();
    await show(tester, sharer: _Sharer(), saver: saver);
    await tester.tap(find.text('Save…'));
    await tester.pumpAndSettle();
    expect(String.fromCharCodes(saver.saved!), report);
  });

  testWidgets('no report says so and offers nothing to send', (tester) async {
    await show(tester, text: null, sharer: _Sharer(), saver: _Saver());
    expect(find.text('The report could not be made.'), findsOne);
    expect(find.text('Share…'), findsNothing);
    expect(find.text('Save…'), findsNothing);
  });

  testWidgets('it reads Spanish and fits a phone', (tester) async {
    tester.view
      ..physicalSize = const Size(360, 720)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await show(tester,
        sharer: _Sharer(), saver: _Saver(), locale: const Locale('es'));
    expect(find.text('Informar de un problema'), findsOne);
    expect(tester.takeException(), isNull);
  });
}

class _Sharer implements TextSharer {
  final shared = <String>[];

  @override
  Future<bool> share(String text, {required String subject}) async {
    shared.add(text);
    return true;
  }
}

class _Saver implements FileSaver {
  Uint8List? saved;

  @override
  Future<SaveOutcome> save({
    required String suggestedName,
    required String mimeType,
    required Uint8List bytes,
    required String dialogTitle,
  }) async {
    saved = bytes;
    return const Saved('somewhere');
  }
}
