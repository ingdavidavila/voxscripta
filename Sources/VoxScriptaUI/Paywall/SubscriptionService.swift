import Foundation
import VoxScriptaCore

/// One thing that can be bought.
///
/// Every string a buyer reads comes from the store. StoreKit returns a price
/// already formatted for the viewer's App Store country and currency — so a
/// UK account sees £3.99 and a Mexican one sees $79.00 MXN, from the price
/// tier set per territory in App Store Connect. A price formatted here would
/// be wrong for most of the world and wrong again the day it changes.
public struct SubscriptionProduct: Sendable, Hashable, Identifiable {
    public let id: String
    public let period: BillingPeriod
    /// What it is called, from the store's own localized display name.
    public let title: String
    /// The store's formatted price, e.g. "£3.99".
    public let price: String
    /// The line under the price, e.g. "per month".
    public let priceDetail: String?
    /// e.g. "Save 37%", or nil when there is nothing to say.
    public let savingNote: String?

    public init(
        id: String,
        period: BillingPeriod,
        title: String,
        price: String,
        priceDetail: String? = nil,
        savingNote: String? = nil
    ) {
        self.id = id
        self.period = period
        self.title = title
        self.price = price
        self.priceDetail = priceDetail
        self.savingNote = savingNote
    }
}

/// Something the purchase went wrong with.
public struct SubscriptionError: Error, Sendable, Hashable {
    public let message: String
    /// True when the buyer backed out, which is not an error and must not be
    /// shown as one.
    public let wasCancelled: Bool

    public init(_ message: String, wasCancelled: Bool = false) {
        self.message = message
        self.wasCancelled = wasCancelled
    }
}

/// What the paywall asks of whatever sells the subscription.
///
/// Mirrors the Flutter side's `SubscriptionService` so `Docs/PARITY.md` holds.
/// The implementation cannot be shared and must not be: Guideline 3.1.1
/// requires StoreKit on Apple platforms, Play's Payments policy requires Play
/// Billing on Android, and a direct Windows or Linux sale is governed by
/// neither.
public protocol SubscriptionService: Sendable {
    /// What is for sale, with prices the store formatted.
    func products() async throws -> [SubscriptionProduct]

    /// Buys one, and records it with the engine on success.
    func purchase(_ product: SubscriptionProduct) async throws

    /// Finds an existing subscription on this store account.
    ///
    /// Not optional. Both stores require a way to restore without paying
    /// again — a new Mac, a reinstall, a second device — and someone made to
    /// buy twice says so in the review.
    func restore() async throws

    /// Where to cancel or change the subscription.
    var managementPage: URL? { get }

    /// The terms the purchase is made under.
    ///
    /// Required *on the paywall itself* by Guideline 3.1.2, next to the price
    /// and the billing period. A required property rather than an optional
    /// one for that reason: a missing EULA link is a rejection, and a silent
    /// one.
    var termsOfUse: URL { get }

    /// Also required on the paywall by 3.1.2.
    var privacyPolicy: URL { get }
}

/// The product identifiers this app sells.
///
/// They have to match App Store Connect and the Play Console exactly, and
/// they are the same two strings on both so the engine's record means the
/// same thing wherever it was written.
public enum SubscriptionProducts {
    public static let monthly = "voxscripta.monthly"
    public static let yearly = "voxscripta.yearly"
    public static let all = [monthly, yearly]

    public static func period(of id: String) -> BillingPeriod? {
        switch id {
        case monthly: .monthly
        case yearly: .yearly
        default: nil
        }
    }
}
