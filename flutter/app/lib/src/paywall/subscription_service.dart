import 'package:voxscripta_engine/voxscripta_engine.dart';

/// One thing that can be bought.
///
/// Every string a user reads comes from the store, not from here. Apple and
/// Google both return a price already formatted for the viewer's country and
/// currency, and a hardcoded "$4.99" is wrong for most of the world and wrong
/// again the day the price changes.
class SubscriptionProduct {
  const SubscriptionProduct({
    required this.id,
    required this.period,
    required this.title,
    required this.price,
    this.priceDetail,
    this.savingNote,
  });

  /// The store's product identifier.
  final String id;

  final BillingPeriod period;

  /// What it is called, e.g. "Monthly".
  final String title;

  /// The store's own formatted price, e.g. "£3.99".
  final String price;

  /// The small print under the price, e.g. "per month" or
  /// "£29.99 a year — £2.50 a month".
  final String? priceDetail;

  /// e.g. "Save 37%". Nil when there is nothing to say.
  final String? savingNote;
}

/// Something the purchase went wrong with.
class SubscriptionException implements Exception {
  const SubscriptionException(this.message, {this.wasCancelled = false});

  final String message;

  /// True when the user backed out, which is not an error and should not be
  /// shown as one.
  final bool wasCancelled;

  @override
  String toString() => 'SubscriptionException: $message';
}

/// Everything the paywall asks of whatever sells the subscription.
///
/// An interface rather than an implementation, because this must be a
/// different implementation on each platform and cannot be anything else:
///
///  * **iOS and macOS** — StoreKit 2. App Store Review Guideline 3.1.1
///    requires it for unlocking features in the app; a card form or a Stripe
///    link is a rejection.
///  * **Android** — Google Play Billing, for the same reason under Play's
///    Payments policy.
///  * **Windows and Linux** — your own, since nobody else's rules apply to a
///    direct download. Microsoft Store builds would need its IAP instead.
///
/// All three verify on the device and offline: StoreKit 2 transactions are
/// signed by Apple and checkable without a server, and Play Billing's
/// purchases likewise. That matters here more than usual — it is why a paywall
/// does not drag a server of ours into an application whose whole premise is
/// that it needs no network.
abstract interface class SubscriptionService {
  /// What is for sale, with prices the store formatted.
  Future<List<SubscriptionProduct>> products();

  /// Buys one. Throws [SubscriptionException] on failure, including a
  /// cancellation, which is flagged rather than described.
  ///
  /// On success the implementation must call
  /// `VoxScriptaEngine.recordSubscription`, because the engine is what
  /// actually opens the gate.
  Future<void> purchase(SubscriptionProduct product);

  /// Finds an existing subscription on this store account.
  ///
  /// Not optional. Both stores require a way to restore purchases without
  /// paying again — a new phone, a reinstall, a second machine — and a user
  /// who has to buy twice will say so in the review.
  Future<void> restore();

  /// Where to cancel or change the subscription. Null when the platform has
  /// no such page.
  Uri? get managementPage;

  /// The terms the purchase is made under.
  ///
  /// Required on the paywall itself by Guideline 3.1.2, alongside the price
  /// and the billing period. Not optional, and not a link in a settings
  /// screen three taps away.
  Uri get termsOfUse;

  /// Also required on the paywall by 3.1.2.
  Uri get privacyPolicy;
}

/// The subscription service this build talks to, or null when there is none.
///
/// Null, and deliberately so, exactly as `configuredAuthService()` is. Nothing
/// here is wired to a store yet.
///
/// Note what that means, because it is not cosmetic: **the engine enforces the
/// wall regardless.** `vs_job_start` and `vs_recording_start` refuse once the
/// three days are up, so a release build shipped in this state would stop
/// transcribing on day four with no way to pay. That is not a bug to be
/// discovered; it is the consequence of putting the wall in the engine, where
/// no interface can forget it. For development, `VOXSCRIPTA_ENTITLEMENT`
/// forces a state in debug builds — see `EntitlementStore.debugOverride`.
///
/// Whoever wires a store replaces this one function, per platform. The
/// paywall screen, the banner and the gating all read the interface above and
/// need no change.
SubscriptionService? configuredSubscriptionService() => null;
