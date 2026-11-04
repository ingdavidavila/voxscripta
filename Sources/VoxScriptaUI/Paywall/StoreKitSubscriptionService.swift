import Foundation
import StoreKit
import VoxScriptaCore
import VoxScriptaProject

/// The subscription, sold through the App Store.
///
/// Real, not a placeholder. StoreKit 2 hands back transactions signed by
/// Apple and `VerificationResult` checks that signature **on the device**, so
/// this needs no server of ours — which matters more here than in most apps,
/// because an application whose premise is that it needs no network should
/// not acquire one in order to take money.
///
/// Until the two products exist in App Store Connect, ``products()`` returns
/// an empty array. That is the honest state and the paywall says so rather
/// than inventing prices.
///
/// What this deliberately does **not** do is decide anything. It verifies a
/// purchase and writes the outcome to ``EntitlementStore``; the engine
/// decides what that entitles anyone to. The wall is in `JobRunner`, where
/// every interface meets it.
public final class StoreKitSubscriptionService: SubscriptionService {

    public init(
        entitlements: EntitlementStore = EntitlementStore(),
        termsOfUse: URL,
        privacyPolicy: URL
    ) {
        self.entitlements = entitlements
        self.termsOfUse = termsOfUse
        self.privacyPolicy = privacyPolicy
    }

    private let entitlements: EntitlementStore
    public let termsOfUse: URL
    public let privacyPolicy: URL

    public var managementPage: URL? {
        // Apple's own subscription management. Deep-linking here is what
        // Guideline 3.1.2 expects instead of a cancellation flow of our own.
        URL(string: "https://apps.apple.com/account/subscriptions")
    }

    // ── What is for sale ────────────────────────────────────────────────────

    public func products() async throws -> [SubscriptionProduct] {
        let storeProducts: [Product]
        do {
            storeProducts = try await Product.products(for: SubscriptionProducts.all)
        } catch {
            throw SubscriptionError(error.localizedDescription)
        }

        // Monthly first, so the cheaper commitment is the one read first and
        // the yearly saving has something to be a saving against.
        let ordered = storeProducts.sorted { lhs, rhs in
            (SubscriptionProducts.period(of: lhs.id) ?? .monthly) == .monthly
                && (SubscriptionProducts.period(of: rhs.id) ?? .monthly) != .monthly
        }
        let monthlyPrice = storeProducts
            .first { $0.id == SubscriptionProducts.monthly }?.price

        return ordered.compactMap { product in
            guard let period = SubscriptionProducts.period(of: product.id) else { return nil }
            return SubscriptionProduct(
                id: product.id,
                period: period,
                title: product.displayName,
                price: product.displayPrice,
                priceDetail: Self.detail(for: product, period: period),
                savingNote: period == .yearly
                    ? Self.saving(yearly: product.price, monthly: monthlyPrice)
                    : nil)
        }
    }

    private static func detail(for product: Product, period: BillingPeriod) -> String? {
        switch period {
        case .monthly: String(localized: "per month")
        case .yearly: String(localized: "per year")
        }
    }

    /// "Save 37%", or nil when there is nothing honest to claim.
    ///
    /// Computed from the two real prices rather than written down, because a
    /// hardcoded percentage becomes a false advertisement the first time
    /// either price moves — and in a currency where the tiers round
    /// differently, it can be false on the day it ships.
    static func saving(yearly: Decimal, monthly: Decimal?) -> String? {
        guard let monthly, monthly > 0 else { return nil }
        let twelve = monthly * 12
        guard yearly < twelve else { return nil }
        let fraction = (twelve - yearly) / twelve
        let percent = Int((fraction as NSDecimalNumber).doubleValue * 100)
        guard percent >= 5 else { return nil }
        return String(localized: "Save \(percent)%")
    }

    // ── Buying ──────────────────────────────────────────────────────────────

    public func purchase(_ product: SubscriptionProduct) async throws {
        let storeProducts = try? await Product.products(for: [product.id])
        guard let storeProduct = storeProducts?.first else {
            throw SubscriptionError(String(localized:
                "That subscription is not available from the App Store right now."))
        }

        let result: Product.PurchaseResult
        do {
            result = try await storeProduct.purchase()
        } catch {
            throw SubscriptionError(error.localizedDescription)
        }

        switch result {
        case .success(let verification):
            let transaction = try verified(verification)
            await record(transaction, for: storeProduct)
            // Finishing tells the store the purchase has been delivered. A
            // transaction left unfinished is replayed on every launch.
            await transaction.finish()

        case .userCancelled:
            throw SubscriptionError(String(localized: "Cancelled."), wasCancelled: true)

        case .pending:
            // Ask to Buy, or a payment method needing approval. Not a
            // failure, and not a success either; saying so beats either.
            throw SubscriptionError(String(localized:
                "That purchase needs approval before it can finish. You will be able to transcribe as soon as it does."))

        @unknown default:
            throw SubscriptionError(String(localized:
                "The App Store returned something this version does not understand."))
        }
    }

    // ── Restoring ───────────────────────────────────────────────────────────

    public func restore() async throws {
        // `currentEntitlements` is the local, signed record of what this
        // Apple ID owns. `AppStore.sync()` is deliberately not called first:
        // it prompts for a password, and Apple's guidance is to reserve it
        // for an explicit Restore button that has already failed.
        var found = false
        for await verification in Transaction.currentEntitlements {
            guard
                let transaction = try? verified(verification),
                SubscriptionProducts.period(of: transaction.productID) != nil,
                transaction.revocationDate == nil
            else { continue }

            let product = try? await Product.products(for: [transaction.productID]).first
            await record(transaction, for: product)
            found = true
        }

        guard found else {
            // Not an error in the sense of something broken, but the person
            // pressed Restore and nothing happened, which needs saying.
            throw SubscriptionError(String(localized:
                "No subscription was found on this Apple Account."))
        }
    }

    // ── Staying current ─────────────────────────────────────────────────────

    /// Watches for renewals, cancellations and refunds.
    ///
    /// Must be running for the whole life of the app. A renewal that arrives
    /// while the app is open, or a refund granted by Apple, shows up here and
    /// nowhere else — without this, a refunded subscription would keep
    /// working until the next launch.
    public func observeTransactions() -> Task<Void, Never> {
        Task.detached { [entitlements] in
            for await verification in Transaction.updates {
                guard case .verified(let transaction) = verification else { continue }
                guard SubscriptionProducts.period(of: transaction.productID) != nil
                else { continue }

                if transaction.revocationDate != nil {
                    _ = entitlements.clearSubscription()
                } else if let period = SubscriptionProducts.period(of: transaction.productID) {
                    _ = entitlements.record(subscription: .init(
                        productID: transaction.productID,
                        period: period,
                        expires: transaction.expirationDate))
                }
                await transaction.finish()
            }
        }
    }

    // ── Plumbing ────────────────────────────────────────────────────────────

    /// Unwraps a transaction only if Apple's signature checks out.
    ///
    /// An unverified result is refused rather than trusted-but-logged. It is
    /// the single thing standing between this and a forged receipt, and it
    /// costs nothing to honour.
    private func verified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, let error):
            throw SubscriptionError(String(localized:
                "That purchase could not be verified with Apple (\(error.localizedDescription))."))
        }
    }

    private func record(_ transaction: Transaction, for product: Product?) async {
        guard let period = SubscriptionProducts.period(of: transaction.productID) else { return }
        _ = entitlements.record(subscription: .init(
            productID: transaction.productID,
            period: period,
            expires: transaction.expirationDate,
            graceUntil: await gracePeriod(for: product)))
    }

    /// Apple's billing-retry grace, when the store has granted one.
    ///
    /// Honoured because a subscriber whose card was declined once should not
    /// lose the app in the middle of an interview while Apple retries.
    private func gracePeriod(for product: Product?) async -> Date? {
        guard let statuses = try? await product?.subscription?.status else { return nil }
        for status in statuses {
            guard case .verified(let renewal) = status.renewalInfo else { continue }
            if let grace = renewal.gracePeriodExpirationDate { return grace }
        }
        return nil
    }
}
