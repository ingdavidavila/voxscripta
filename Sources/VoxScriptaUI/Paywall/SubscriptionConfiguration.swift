import Foundation

/// The store this build sells through.
///
/// ``StoreKitSubscriptionService`` is written, real and ready: StoreKit 2
/// verifies on the device, so it needs no server. The Terms of Use and
/// Privacy Policy URLs it requires are published from the `gh-pages` branch
/// and named in ``SubscriptionLinks`` below.
///
/// One thing is still missing, and it is outside the code: **the two products
/// in App Store Connect** — `voxscripta.monthly` and `voxscripta.yearly`,
/// with a price tier per territory. Until they exist,
/// `Product.products(for:)` returns nothing and the paywall says so instead
/// of inventing prices.
///
/// This returns the service anyway, rather than nil, so that the code path
/// exercised in a debug build is the same one that ships. A debug build run
/// from Xcode gets its products from `ios/VoxScripta.storekit` instead of the
/// real store, which is the only way to see a purchase complete before the
/// products exist. Returning nil would have meant the purchase flow was
/// untested until the day it was also unchangeable.
///
/// Note what does *not* change here: the engine enforces the wall in
/// `JobRunner`, on every platform, whether or not anything is for sale. A
/// release build shipped before those products exist still stops transcribing
/// on day four with no way to pay — a wired service does not fix that, and
/// only App Store Connect can.
public func configuredSubscriptionService() -> (any SubscriptionService)? {
    StoreKitSubscriptionService(
        termsOfUse: SubscriptionLinks.termsOfUse,
        privacyPolicy: SubscriptionLinks.privacyPolicy)
}


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
