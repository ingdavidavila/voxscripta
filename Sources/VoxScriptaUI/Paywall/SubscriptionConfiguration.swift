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
///  2. ~~A public Terms of Use URL and Privacy Policy URL.~~ **Done.** Both
///     are published from the `gh-pages` branch and are named in
///     ``SubscriptionLinks`` below. Guideline 3.1.2 requires them on the
///     paywall itself, which is why they are required arguments rather than
///     optional ones. Two placeholders remain *inside* those pages — the
///     contact address and the state for the governing-law clause — and both
///     must be filled before submission.
///
/// Returning nil until those exist is the honest state. The alternative —
/// shipping the service with placeholder links — would put two dead URLs in
/// front of a buyer on the screen where the law expects real ones.
///
/// To turn the paywall on, return the service with the published links:
///
///     StoreKitSubscriptionService(
///         termsOfUse: SubscriptionLinks.termsOfUse,
///         privacyPolicy: SubscriptionLinks.privacyPolicy)
///
/// Note what does *not* change when you do: the engine already enforces the
/// wall in `JobRunner`, on every platform, whether or not anything is for
/// sale. A build shipped before this returns a service stops transcribing on
/// day four with no way to pay.
public func configuredSubscriptionService() -> (any SubscriptionService)? { nil }


/// Where the legal pages live.
///
/// Published from the repository's `gh-pages` branch, which is an orphan
/// branch holding only the site. GitHub Pages cannot serve from `Docs/`
/// here — its `/docs` source option matches a lower-case directory and git
/// records this one capitalised — so a branch is the route that needs no
/// renaming of the source tree.
///
/// Force-unwrapped on purpose. These are compile-time constants, not input,
/// and a typo should fail on the first launch of a debug build rather than
/// become a silently absent link on the one screen where Review Guideline
/// 3.1.2 requires one.
public enum SubscriptionLinks {
    public static let privacyPolicy =
        URL(string: "https://ingdavidavila.github.io/voxscripta/privacy.html")!
    public static let termsOfUse =
        URL(string: "https://ingdavidavila.github.io/voxscripta/terms.html")!
}
