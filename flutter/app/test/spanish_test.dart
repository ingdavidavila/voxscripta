import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/l10n/app_localizations.dart';
import 'package:voxscripta/src/paywall/paywall_screen.dart';
import 'package:voxscripta/src/paywall/trial_banner.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The Spanish interface.
///
/// The translations are drafts by a model and not yet read by a native
/// speaker, so what these tests can honestly pin is the mechanics: every
/// English string has a Spanish one with the same placeholders, counts and
/// percentages render, and the longer Spanish text still fits a phone.
Map<String, dynamic> _arb(String name) => jsonDecode(
        File('lib/l10n/$name.arb').readAsStringSync())
    as Map<String, dynamic>;

Set<String> _placeholders(String text) =>
    RegExp(r'\{(\w+)[,}]').allMatches(text).map((m) => m.group(1)!).toSet();

Locale _locale = const Locale('es');

void main() {
  final en = _arb('app_en');
  final es = _arb('app_es');
  final keys = en.keys.where((k) => !k.startsWith('@'));

  test('every English string has a Spanish one', () {
    expect(keys.where((k) => !es.containsKey(k)), isEmpty);
    expect(es.keys.where((k) => !k.startsWith('@') && !en.containsKey(k)),
        isEmpty);
  });

  test('Spanish uses the same placeholders as English', () {
    for (final k in keys) {
      if (k == '@@locale') continue;
      expect(_placeholders(es[k] as String), _placeholders(en[k] as String),
          reason: k);
    }
  });

  final l10n = lookupAppLocalizations(const Locale('es'));

  test('counts and percentages render', () {
    expect(l10n.trialDaysLeft(2), 'Quedan 2 días de tu prueba gratuita.');
    expect(l10n.hoursAgo(1), 'hace 1 hora');
    expect(l10n.hoursAgo(5), 'hace 5 horas');
    expect(l10n.daysAgo(1), 'hace 1 día');
    expect(l10n.daysAgo(3), 'hace 3 días');
    expect(l10n.speechSummary(4, 87), contains('el 87% de la grabación'));
  });

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view
      ..physicalSize = const Size(360, 2400)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: _locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the trial banner reads Spanish and fits a phone',
      (tester) async {
    await pump(
      tester,
      Scaffold(
        body: TrialBanner(
          entitlement: const Entitlement(
            state: EntitlementState.trialing,
            allowsNewWork: true,
            shouldOfferSubscription: true,
            trialDays: 3,
            trialDaysRemaining: 2,
          ),
          onSubscribe: (_) {},
        ),
      ),
    );
    expect(find.text('Quedan 2 días de tu prueba gratuita.'), findsOne);
    expect(find.text('Ver planes'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the paywall fits a phone in Spanish', (tester) async {
    await pump(
      tester,
      PaywallScreen(
        entitlement: const Entitlement(
          state: EntitlementState.trialExpired,
          allowsNewWork: false,
          shouldOfferSubscription: true,
          trialDays: 3,
        ),
      ),
    );
    expect(find.text('Tu prueba de 3 días ha terminado'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Material widgets are Spanish too', (tester) async {
    await pump(tester, const Scaffold(body: SizedBox()));
    final context = tester.element(find.byType(Scaffold));
    expect(MaterialLocalizations.of(context).backButtonTooltip, 'Atrás');
  });

  testWidgets('control: English paywall at the same width', (tester) async {
    _locale = const Locale('en');
    addTearDown(() => _locale = const Locale('es'));
    await pump(
      tester,
      PaywallScreen(
        entitlement: const Entitlement(
          state: EntitlementState.trialExpired,
          allowsNewWork: false,
          shouldOfferSubscription: true,
          trialDays: 3,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
