import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxscripta/src/paywall/paywall_screen.dart';
import 'package:voxscripta/src/paywall/subscription_service.dart';
import 'package:voxscripta/src/paywall/trial_banner.dart';
import 'package:voxscripta_engine/voxscripta_engine.dart';

/// The paywall.
///
/// Two things are pinned hardest. First, that the screen carries the
/// disclosures App Store Review Guideline 3.1.2 requires on the paywall
/// itself — the price, the billing period, and links to the Terms of Use and
/// the Privacy Policy — because a missing link is a rejection and a silent
/// one. Second, that the screen says what the wall does *not* take, since a
/// user who hits a paywall assumes their recordings are gone and in this app
/// they are not.
void main() {
  Entitlement entitlement({
    EntitlementState state = EntitlementState.trialExpired,
    bool allows = false,
    bool offer = true,
    int? daysRemaining,
    BillingPeriod? period,
    String? refusal,
  }) =>
      Entitlement(
        state: state,
        allowsNewWork: allows,
        shouldOfferSubscription: offer,
        trialDays: 3,
        trialDaysRemaining: daysRemaining,
        period: period,
        refusal: refusal,
      );

  Future<void> showPaywall(
    WidgetTester tester, {
    Entitlement? state,
    SubscriptionService? service,
    void Function(BuildContext)? onSubscribed,
    List<Uri>? opened,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: PaywallScreen(
        entitlement: state ?? entitlement(),
        service: service,
        onSubscribed: onSubscribed,
        onOpenLink: opened?.add,
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Scrolls to the foot of the paywall, where the required small print is.
  ///
  /// The list is lazy, so the disclosure does not exist as a widget until it
  /// is scrolled into range — and asserting on it from a deliberately
  /// oversized test window would prove only that a 2000px screen can see it.
  Future<void> scrollToSmallPrint(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Terms of Use'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  group('Paywall', () {
    testWidgets('the plans come from the store, prices and all', (tester) async {
      await showPaywall(tester, service: _Store());

      expect(find.text('Monthly'), findsOne);
      expect(find.text('Yearly'), findsOne);
      // The store formats the price for the viewer's country. A price
      // formatted here would be wrong for most of the world.
      expect(find.text('£3.99'), findsOne);
      expect(find.text('£29.99'), findsOne);
      expect(find.text('Save 37%'), findsOne);
    });

    testWidgets('the billing period and renewal terms are on this screen',
        (tester) async {
      await showPaywall(tester, service: _Store());

      expect(find.textContaining('per month'), findsOne);
      await scrollToSmallPrint(tester);
      expect(find.textContaining('renew automatically'), findsOne);
    });

    testWidgets('both required legal links are present and open',
        (tester) async {
      final opened = <Uri>[];
      await showPaywall(tester, service: _Store(), opened: opened);
      await scrollToSmallPrint(tester);

      // Guideline 3.1.2 requires both, on the paywall itself.
      expect(find.text('Terms of Use'), findsOne);
      expect(find.text('Privacy Policy'), findsOne);

      await tester.tap(find.text('Terms of Use'));
      await tester.pumpAndSettle();
      expect(opened.single.path, contains('terms'));
    });

    testWidgets('it says what the wall does not take', (tester) async {
      await showPaywall(tester, service: _Store());

      expect(find.textContaining('stays yours'), findsOne);
      expect(find.textContaining('untouched'), findsOne);
      expect(find.textContaining('exportable'), findsOne);
    });

    testWidgets('a purchase is passed to the store and reported back',
        (tester) async {
      final store = _Store();
      var done = false;
      await showPaywall(tester,
          service: store, onSubscribed: (_) => done = true);

      await tester.tap(find.text('Yearly'));
      await tester.pumpAndSettle();

      expect(store.purchased, ['voxscripta.yearly']);
      expect(done, isTrue);
    });

    testWidgets('a failed purchase stays on the screen and says why',
        (tester) async {
      final store = _Store(
          failure: const SubscriptionException('The payment was declined.'));
      var done = false;
      await showPaywall(tester,
          service: store, onSubscribed: (_) => done = true);

      await tester.tap(find.text('Monthly'));
      await tester.pumpAndSettle();

      expect(find.text('The payment was declined.'), findsOne);
      expect(done, isFalse);
    });

    testWidgets('backing out of the store sheet is not shown as an error',
        (tester) async {
      final store = _Store(
          failure: const SubscriptionException('cancelled', wasCancelled: true));
      await showPaywall(tester, service: store);

      await tester.tap(find.text('Monthly'));
      await tester.pumpAndSettle();

      // Someone who changed their mind has not hit a problem.
      expect(find.text('cancelled'), findsNothing);
    });

    testWidgets('restoring is offered, and reports back when it finds one',
        (tester) async {
      final store = _Store();
      var done = false;
      await showPaywall(tester,
          service: store, onSubscribed: (_) => done = true);

      // Both stores require this, and a user made to pay twice says so in the
      // review.
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(store.restores, 1);
      expect(done, isTrue);
    });

    testWidgets('a store that will not list its products says so',
        (tester) async {
      await showPaywall(
          tester,
          service: _Store(
              listFailure:
                  const SubscriptionException('The App Store did not answer.')));
      expect(find.text('The App Store did not answer.'), findsOne);
    });

    testWidgets('with no store wired it says that, and offers nothing',
        (tester) async {
      await showPaywall(tester);

      // Honest about a real dead end rather than showing a button that throws.
      expect(find.textContaining('No store is connected'), findsOne);
      expect(find.text('Restore'), findsNothing);
      expect(find.text('Monthly'), findsNothing);
    });

    testWidgets('the headline fits the reason the wall is up', (tester) async {
      await showPaywall(tester, state: entitlement());
      expect(find.textContaining('3-day trial has ended'), findsOne);

      await showPaywall(tester,
          state: entitlement(state: EntitlementState.subscriptionLapsed));
      expect(find.textContaining('subscription has lapsed'), findsOne);

      await showPaywall(tester,
          state: entitlement(
              state: EntitlementState.trialing, allows: true, daysRemaining: 2));
      expect(find.textContaining('Keep going'), findsOne);
    });

    testWidgets('it does not claim a subscription changes where work happens',
        (tester) async {
      await showPaywall(tester, service: _Store());
      // The app is local either way; saying otherwise to sell a subscription
      // would be the one lie this screen could tell.
      expect(find.textContaining('transcribes on this machine'), findsOne);
    });
  });

  group('Trial banner', () {
    Future<void> showBanner(WidgetTester tester, Entitlement state,
        {void Function(BuildContext)? onSubscribe}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TrialBanner(entitlement: state, onSubscribe: onSubscribe)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('it counts the days down during the trial', (tester) async {
      await showBanner(
          tester,
          entitlement(
              state: EntitlementState.trialing, allows: true, daysRemaining: 2));
      expect(find.text('2 days left in your free trial.'), findsOne);
    });

    testWidgets('the last day is named, not counted', (tester) async {
      await showBanner(
          tester,
          entitlement(
              state: EntitlementState.trialing, allows: true, daysRemaining: 1));
      expect(find.text('Last day of your free trial.'), findsOne);
    });

    testWidgets('it appears during the trial, not only after it',
        (tester) async {
      await showBanner(
          tester,
          entitlement(
              state: EntitlementState.trialing, allows: true, daysRemaining: 3),
          onSubscribe: (_) {});
      // A wall that says nothing for three days and then appears is a
      // bait-and-switch.
      expect(find.text('See plans'), findsOne);
    });

    testWidgets('once the trial is over it offers to subscribe',
        (tester) async {
      await showBanner(tester, entitlement(), onSubscribe: (_) {});
      expect(find.text('Subscribe'), findsOne);
      expect(find.textContaining('stays yours'), findsOne);
    });

    testWidgets('a subscriber is not advertised to', (tester) async {
      await showBanner(
          tester,
          entitlement(
              state: EntitlementState.subscribed,
              allows: true,
              offer: false,
              period: BillingPeriod.yearly),
          onSubscribe: (_) {});
      expect(find.text('Subscribe'), findsNothing);
      expect(find.text('See plans'), findsNothing);
    });
  });
}

/// A store that records what it was asked to do.
class _Store implements SubscriptionService {
  _Store({this.failure, this.listFailure});

  final SubscriptionException? failure;
  final SubscriptionException? listFailure;
  final List<String> purchased = [];
  int restores = 0;

  @override
  Future<List<SubscriptionProduct>> products() async {
    if (listFailure case final f?) throw f;
    return const [
      SubscriptionProduct(
        id: 'voxscripta.monthly',
        period: BillingPeriod.monthly,
        title: 'Monthly',
        price: '£3.99',
        priceDetail: 'per month',
      ),
      SubscriptionProduct(
        id: 'voxscripta.yearly',
        period: BillingPeriod.yearly,
        title: 'Yearly',
        price: '£29.99',
        priceDetail: 'per year — £2.50 a month',
        savingNote: 'Save 37%',
      ),
    ];
  }

  @override
  Future<void> purchase(SubscriptionProduct product) async {
    if (failure case final f?) throw f;
    purchased.add(product.id);
  }

  @override
  Future<void> restore() async {
    if (failure case final f?) throw f;
    restores += 1;
  }

  @override
  Uri? get managementPage => Uri.parse('https://example.com/manage');

  @override
  Uri get termsOfUse => Uri.parse('https://example.com/terms');

  @override
  Uri get privacyPolicy => Uri.parse('https://example.com/privacy');
}
