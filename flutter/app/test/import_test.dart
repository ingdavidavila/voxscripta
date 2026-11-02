import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/import/file_chooser.dart';
import 'package:voxscripta/src/import/import_sheet.dart';

/// Importing a file.
///
/// The dialog itself is the platform's and cannot be driven from a test — so
/// what is pinned here is the half that can go wrong silently: whether a path
/// is checked before a project is created for it, and whether the typed route
/// works at all, since on a machine with no desktop dialog it is the only
/// route there is.
void main() {
  late Directory directory;

  setUp(() => directory = Directory.systemTemp.createTempSync('import-test'));
  tearDown(() => directory.deleteSync(recursive: true));

  File audio(String name) {
    final file = File('${directory.path}/$name')..writeAsBytesSync([0, 1, 2]);
    return file;
  }

  Future<ImportChoice?> open(WidgetTester tester, {FileChooser? chooser}) async {
    ImportChoice? chosen;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            chosen = await ImportSheet.show(
              context,
              chooser: chooser ?? const _NoDialog(),
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return chosen;
  }

  testWidgets('a typed path to a real audio file is accepted', (tester) async {
    final file = audio('interview.m4a');
    await open(tester);

    await tester.enterText(find.byType(TextField), file.path);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.byType(ImportSheet), findsNothing);
  });

  testWidgets('a path that is not there is refused before anything is created',
      (tester) async {
    await open(tester);

    await tester.enterText(find.byType(TextField), '${directory.path}/nope.m4a');
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Checked here rather than left to the engine: its refusal arrives
    // asynchronously on a job that already exists, and a project for a file
    // that is not there is litter.
    expect(find.text('There is no file at that path.'), findsOne);
    expect(find.byType(ImportSheet), findsOne);
  });

  testWidgets('a format the decoder cannot read is refused by name',
      (tester) async {
    final file = audio('notes.pdf');
    await open(tester);

    await tester.enterText(find.byType(TextField), file.path);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Said now rather than a minute into a job, which is when the decoder
    // would otherwise say it.
    expect(find.textContaining('cannot read .pdf files'), findsOne);
  });

  testWidgets('an empty path says so rather than doing nothing',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a file, or type its path.'), findsOne);
  });

  testWidgets('the file is promised to stay where it is', (tester) async {
    await open(tester);
    // §5, where the decision is being made.
    expect(find.textContaining('never modifies it'), findsOne);
  });

  testWidgets('without a dialog, the typed path is the whole interface',
      (tester) async {
    await open(tester, chooser: const _NoDialog());
    expect(find.text('Choose a file…'), findsNothing);
    expect(find.byType(TextField), findsOne);
  });

  testWidgets('with a dialog, both routes are offered', (tester) async {
    await open(tester, chooser: const _HasDialog());
    expect(find.text('Choose a file…'), findsOne);
    expect(find.byType(TextField), findsOne);
  });

  group('FileChooser', () {
    test('offers the formats the pipeline can actually decode', () {
      // The same list the SwiftUI open panel offers, so neither interface
      // accepts a file the other would refuse.
      expect(FileChooser.audioExtensions, contains('m4a'));
      expect(FileChooser.audioExtensions, contains('wav'));
      expect(FileChooser.audioExtensions, contains('mp3'));
      expect(FileChooser.audioExtensions, contains('flac'));
      expect(FileChooser.audioExtensions, isNot(contains('pdf')));
    });

    test('a dialog is expected on every desktop this app targets', () {
      // Android is deliberately not covered — there is no shell dialog there,
      // and that is where a plugin has to arrive.
      expect(const FileChooser().isAvailable,
          Platform.isMacOS || Platform.isLinux || Platform.isWindows);
    });
  });
}

/// A machine with no desktop dialog, which is the case the typed path exists
/// for.
class _NoDialog implements FileChooser {
  const _NoDialog();

  @override
  bool get isAvailable => false;

  @override
  Future<String?> choose() async => null;
}

class _HasDialog implements FileChooser {
  const _HasDialog();

  @override
  bool get isAvailable => true;

  @override
  Future<String?> choose() async => null;
}
