import Foundation

/// The store this build sells through, or nil when it cannot yet.
///
/// ``StoreKitSubscriptionService`` is written, real and ready: StoreKit 2
/// verifies on the device, so it needs no server. Two things are still
/// missing, and both are outside the code:
///
///  1. **The two products in App Store Connect** — `voxscripta.monthly` and
///     `voxscripta.yearly`, with a price tier per territory. Until they
///     exist, `Product.products(for:)` returns nothing.
///  2. **A public Terms of Use URL and Privacy Policy URL.** Review Guideline
///     3.1.2 requires both *on the paywall itself*, which is why they are
///     required arguments rather than optional ones. The privacy policy has
///     no public address yet — it is the same blocker that holds up both
///     store submissions.
///
/// Returning nil until those exist is the honest state. The alternative —
/// shipping the service with placeholder links — would put two dead URLs in
/// front of a buyer on the screen where the law expects real ones.
///
/// To turn the paywall on, fill in both URLs and return the service:
///
///     StoreKitSubscriptionService(
///         termsOfUse: URL(string: "https://…/terms")!,
///         privacyPolicy: URL(string: "https://…/privacy")!)
///
/// Note what does *not* change when you do: the engine already enforces the
/// wall in `JobRunner`, on every platform, whether or not anything is for
/// sale. A build shipped before this returns a service stops transcribing on
/// day four with no way to pay.
public func configuredSubscriptionService() -> (any SubscriptionService)? { nil }
