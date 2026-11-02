import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/library/library_model.dart';
import 'package:voxscripta/src/library/library_screen.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The library screen.
///
/// These are about the screen and not about the engine: what it shows with
/// nothing in it, that it asks before destroying anything, and that a failure
/// arrives as the engine's own words rather than a paraphrase. The boundary
/// itself is tested properly in `voxscripta_engine` against a real library, so
/// a stub here is the right tool rather than a shortcut.
void main() {
  ProjectEntry entry(String name, {String? id, Duration? length}) => ProjectEntry(
        id: id ?? name,
        path: '/library/$name.voxscripta',
        displayName: name,
        duration: length ?? const Duration(minutes: 3, seconds: 7, milliseconds: 250),
        state: JobState.complete,
        modifiedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );

  Future<void> show(WidgetTester tester, LibraryModel model) async {
    await tester.pumpWidget(MaterialApp(home: LibraryScreen(model: model)));
    await tester.pumpAndSettle();
  }

  testWidgets('an empty library says so, and says where', (tester) async {
    final source = _StubSource(const []);
    await show(tester, LibraryModel(source));

    expect(find.text('No recordings yet'), findsOne);
    // The folder is part of the message: "nothing here" is far less useful
    // when it does not say where "here" is.
    expect(find.textContaining('/library'), findsOne);
  });

  testWidgets('projects are listed with duration and date', (tester) async {
    await show(tester, LibraryModel(_StubSource([entry('Interview'), entry('Standup')])));

    expect(find.text('Interview'), findsOne);
    expect(find.text('Standup'), findsOne);
    // Formatted exactly as MediaTime.description does it, milliseconds
    // included, because the SwiftUI row shows that and two interfaces
    // formatting one number two ways is the first drift.
    expect(find.textContaining('3:07.250'), findsExactly(2));
  });

  testWidgets('a failure shows the engine\'s own words, with a retry',
      (tester) async {
    final source = _StubSource(const [],
        listFailure: 'the library could not be read at /nope');
    await show(tester, LibraryModel(source));

    expect(find.text('The library could not be read'), findsOne);
    expect(find.textContaining('/nope'), findsOne);

    source.listFailure = null;
    source.projects = [entry('Recovered')];
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Recovered'), findsOne);
  });

  testWidgets('deleting asks first, and cancelling deletes nothing',
      (tester) async {
    final source = _StubSource([entry('Precious')]);
    final model = LibraryModel(source);
    await show(tester, model);

    model.select('Precious');
    // Driven through the model rather than through a long-press, because the
    // gesture that opens the menu is platform-dependent and the confirmation
    // is not — it is the part that must never be skipped.
    final context = tester.element(find.byType(LibraryScreen));
    await _invokeDelete(tester, context, source.projects.first);

    expect(find.textContaining('Delete Precious?'), findsOne);
    // §5, said where the decision is being made.
    expect(find.textContaining('original audio file is not touched'), findsOne);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.deleted, isEmpty);
    expect(find.text('Precious'), findsOne);
  });

  testWidgets('confirming deletes, and reports where it went', (tester) async {
    final source = _StubSource([entry('Doomed')], movedTo: '/Trash/Doomed');
    final model = LibraryModel(source);
    await show(tester, model);

    final context = tester.element(find.byType(LibraryScreen));
    await _invokeDelete(tester, context, source.projects.first);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(source.deleted, ['/library/Doomed.voxscripta']);
    expect(find.textContaining('/Trash/Doomed'), findsOne);
  });

  group('LibraryModel', () {
    test('a selection that no longer exists is dropped on refresh', () {
      final source = _StubSource([entry('Gone')]);
      final model = LibraryModel(source)..refresh();
      model.select('Gone');
      expect(model.selected, isNotNull);

      source.projects = const [];
      model.refresh();
      // Otherwise a Delete keypress would act on a project that is not there.
      expect(model.selectedId, isNull);
      expect(model.selected, isNull);
    });

    test('a failed list leaves no stale projects on screen', () {
      final source = _StubSource([entry('One')]);
      final model = LibraryModel(source)..refresh();
      expect(model.projects, hasLength(1));

      source.listFailure = 'gone';
      model.refresh();
      expect(model.projects, isEmpty);
      expect(model.error, 'gone');
    });
  });
}

/// Reaches the screen's delete flow without depending on which gesture opens
/// the menu on this platform.
Future<void> _invokeDelete(
    WidgetTester tester, BuildContext context, ProjectEntry project) async {
  final state = tester.state<State<LibraryScreen>>(find.byType(LibraryScreen));
  // Deliberately not awaited. The method awaits showDialog, which does not
  // complete until something taps a button — awaiting it here deadlocked the
  // whole test run, with flutter_tester sitting at 0% CPU for twelve minutes.
  // ignore: avoid_dynamic_calls, unawaited_futures
  (state as dynamic).confirmDeleteForTest(project);
  await tester.pumpAndSettle();
}

class _StubSource implements LibrarySource {
  _StubSource(this.projects, {this.listFailure, this.movedTo});

  List<ProjectEntry> projects;
  String? listFailure;
  String? movedTo;
  final List<String> deleted = [];

  @override
  String get directory => '/library';

  @override
  List<ProjectEntry> list() {
    if (listFailure case final message?) throw VoxScriptaException(message);
    return projects;
  }

  @override
  String? delete(String path) {
    deleted.add(path);
    projects = projects.where((p) => p.path != path).toList();
    return movedTo;
  }
}
