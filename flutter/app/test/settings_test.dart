import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/settings/settings_model.dart';
import 'package:voxscripta/src/settings/settings_screen.dart';
import 'package:voxscripta/src/settings/settings_store.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The settings screen.
///
/// What matters here is not that the controls render — it is that no number in
/// this screen is its own. Every default comes from the engine, a change is
/// recorded as an override and nothing else, and resetting really does return
/// the engine's values rather than a second set written down in Dart.
const engineDefaults = <String, Object?>{
    'locale': 'en-US',
    'detectLanguage': true,
    'concurrency': 4,
    'keepIntermediates': false,
    'polishEnabled': true,
    'polishBackend': 'automatic',
    'silence': {
      'marginDB': 6.0,
      'minSilenceDuration': 0.5,
      'padTrail': 0.2,
      'padLead': 0.1,
    },
    'chunking': {'maxDuration': 300.0},
    'clean': {
      'removeFillers': true,
      'collapseRepetitions': true,
      'dropLowConfidence': true,
    },
  };

void main() {

  Capabilities capabilities({
    bool polishValidated = true,
    bool hasTextSupport = true,
    String? effective = 'Apple on-device model',
    String? unavailableReason,
  }) =>
      Capabilities(
        locales: [
          LocaleOption(
            identifier: 'en-US',
            displayName: 'English (United States)',
            hasTextSupport: hasTextSupport,
            polishValidated: polishValidated,
          ),
          const LocaleOption(
            identifier: 'es-ES',
            displayName: 'Spanish (Spain)',
            hasTextSupport: true,
            polishValidated: true,
          ),
        ],
        polish: PolishCapability(
          systemModelAvailable: effective != null,
          bundledModel: 'Qwen2.5-1.5B-Instruct-4bit',
          effective: effective,
          unavailableReason: unavailableReason,
        ),
      );

  group('SettingsModel', () {
    test('every value starts as the engine\'s, not as a literal', () {
      final model = SettingsModel(source: _Stub(capabilities: capabilities()))
        ..load();

      expect(model.concurrency, 4);
      expect(model.silenceMarginDB, 6.0);
      expect(model.maximumChunkSeconds, 300.0);
      expect(model.removeFillers, isTrue);
      expect(model.hasOverrides, isFalse);
    });

    test('a change becomes an override, and only that one', () {
      final model = SettingsModel(source: _Stub(capabilities: capabilities()))
        ..load();
      model.set('concurrency', 8);

      expect(model.concurrency, 8);
      // Nothing else moves: the rest is still whatever the engine says.
      expect(model.locale, 'en-US');
      expect(model.toJobOptions().concurrency, 8);
      expect(model.toJobOptions().locale, isNull);
    });

    test('setting a value back to the engine\'s default stops overriding it',
        () {
      final model = SettingsModel(source: _Stub(capabilities: capabilities()))
        ..load();
      model.set('concurrency', 8);
      expect(model.hasOverrides, isTrue);

      model.set('concurrency', 4);
      // Otherwise the interface would pin today's default forever, and a
      // change in the engine would silently not reach this user.
      expect(model.hasOverrides, isFalse);
      expect(model.toJobOptions().concurrency, isNull);
    });

    test('reset returns the engine\'s values', () {
      final model = SettingsModel(source: _Stub(capabilities: capabilities()))
        ..load();
      model.set('concurrency', 8);
      model.setNested('clean', 'removeFillers', false);
      expect(model.removeFillers, isFalse);

      model.reset();
      expect(model.concurrency, 4);
      expect(model.removeFillers, isTrue);
      expect(model.hasOverrides, isFalse);
    });

    test('polish availability is the engine\'s answer, per language', () {
      final model = SettingsModel(
          source: _Stub(capabilities: capabilities(polishValidated: false)))
        ..load();
      expect(model.polishSupportedHere, isFalse);
      expect(model.textStagesSupportedHere, isTrue);
    });

    test('overrides survive a reload', () {
      final directory = Directory.systemTemp.createTempSync('settings-test');
      addTearDown(() => directory.deleteSync(recursive: true));
      final store = SettingsStore(directory: directory.path);

      SettingsModel(source: _Stub(capabilities: capabilities()), store: store)
        ..load()
        ..set('concurrency', 2);

      final reopened =
          SettingsModel(source: _Stub(capabilities: capabilities()), store: store)
            ..load();
      expect(reopened.concurrency, 2);
    });

    test('a corrupt settings file costs a preference, not the launch', () {
      final directory = Directory.systemTemp.createTempSync('settings-test');
      addTearDown(() => directory.deleteSync(recursive: true));
      File('${directory.path}/flutter-settings.json')
          .writeAsStringSync('{not json');

      final model = SettingsModel(
        source: _Stub(capabilities: capabilities()),
        store: SettingsStore(directory: directory.path),
      )..load();

      expect(model.concurrency, 4);
      expect(model.error, isNull);
    });
  });

  group('SettingsScreen', () {
    Future<SettingsModel> show(WidgetTester tester, SettingsModel model) async {
      // A tall surface, because ListView builds lazily: the polish section sits
      // below the fold at the default 800x600 and the first version of these
      // tests failed looking for text that had never been built. Scrolling
      // would also work; a viewport the whole form fits in keeps the tests
      // about the content rather than about reaching it.
      tester.view
        ..physicalSize = const Size(900, 2400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(home: SettingsScreen(model: model)));
      await tester.pumpAndSettle();
      return model;
    }

    testWidgets('shows what would actually run', (tester) async {
      await show(tester,
          SettingsModel(source: _Stub(capabilities: capabilities())));
      expect(find.text('Will use'), findsOne);
      // The engine's own words, which are also what the provenance records.
      expect(find.text('Apple on-device model'), findsOne);
    });

    testWidgets('says why nothing will run, when nothing will', (tester) async {
      await show(
        tester,
        SettingsModel(
            source: _Stub(
                capabilities: capabilities(
          effective: null,
          unavailableReason: 'no local language model is available to polish with',
        ))),
      );
      expect(find.textContaining('no local language model'), findsOne);
    });

    testWidgets('an unvalidated language disables polish and says so',
        (tester) async {
      await show(
        tester,
        SettingsModel(
            source: _Stub(capabilities: capabilities(polishValidated: false))),
      );
      expect(find.textContaining('Polished is unavailable in this language'),
          findsOne);
    });

    testWidgets('a language the text stages do not know says verbatim only',
        (tester) async {
      await show(
        tester,
        SettingsModel(
            source: _Stub(
                capabilities: capabilities(hasTextSupport: false))),
      );
      expect(find.textContaining('Verbatim only in this language'), findsOne);
    });

    testWidgets('reset is offered only once something has been changed',
        (tester) async {
      final model = await show(
          tester, SettingsModel(source: _Stub(capabilities: capabilities())));

      final button = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Reset to defaults'));
      expect(button.onPressed, isNull);

      model.set('concurrency', 8);
      await tester.pumpAndSettle();
      final enabled = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Reset to defaults'));
      expect(enabled.onPressed, isNotNull);
    });
  });

  group('SettingsStore', () {
    test('writes atomically and reads back', () {
      final directory = Directory.systemTemp.createTempSync('store-test');
      addTearDown(() => directory.deleteSync(recursive: true));
      final store = SettingsStore(directory: directory.path);

      expect(store.save({'concurrency': 2}), isTrue);
      expect(store.load(), {'concurrency': 2});
      // No temporary left behind: the rename is the commit.
      expect(File('${directory.path}/flutter-settings.json.tmp').existsSync(),
          isFalse);
    });

    test('a missing file is an empty set, not a failure', () {
      final directory = Directory.systemTemp.createTempSync('store-test');
      addTearDown(() => directory.deleteSync(recursive: true));
      expect(SettingsStore(directory: directory.path).load(), isEmpty);
    });
  });
}

class _Stub implements SettingsSource {
  _Stub({required Capabilities capabilities}) : capabilitiesValue = capabilities;

  final Capabilities capabilitiesValue;

  @override
  Map<String, Object?> get jobDefaults => engineDefaults;

  @override
  Capabilities capabilities() => capabilitiesValue;

  @override
  String get libraryDirectory => '/library';
}
