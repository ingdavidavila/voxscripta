import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaProject
@testable import VoxScriptaUI

/// The Apple paywall.
///
/// The engine decides what anyone is entitled to; these pin what the
/// interface says about it, and the one number this screen computes itself.
@MainActor
@Suite("Paywall")
struct PaywallTests {

    private func store(startedDaysAgo days: Double) -> EntitlementStore {
        let store = EntitlementStore(location: FileManager.default.temporaryDirectory
            .appending(path: "voxscripta-paywall-\(UUID().uuidString)")
            .appending(path: "entitlement.json"))
        _ = store.state(now: Date().addingTimeInterval(-days * 86_400))
        return store
    }

    // ── What the interface reports ──────────────────────────────────────────

    @Test("Inside the trial, work is allowed and a plan is still offered")
    func trialAllowsAndStillSells() {
        let model = EntitlementModel(entitlements: store(startedDaysAgo: 1), service: nil)
        #expect(model.allowsNewWork)
        #expect(model.trialDaysRemaining == 2)
        // Offered during the trial too. A wall that appears unannounced on
        // the morning of day four reads as a bait-and-switch.
        #expect(model.shouldOfferSubscription)
    }

    @Test("After the trial, work is refused and a plan is offered")
    func expiredRefuses() {
        let model = EntitlementModel(entitlements: store(startedDaysAgo: 4), service: nil)
        #expect(!model.allowsNewWork)
        #expect(model.trialDaysRemaining == nil)
        #expect(model.shouldOfferSubscription)
    }

    @Test("A subscriber is not advertised to")
    func subscriberIsLeftAlone() {
        let entitlements = store(startedDaysAgo: 90)
        _ = entitlements.record(subscription: .init(
            productID: SubscriptionProducts.yearly,
            period: .yearly,
            expires: Date().addingTimeInterval(200 * 86_400)))

        let model = EntitlementModel(entitlements: entitlements, service: nil)
        #expect(model.allowsNewWork)
        #expect(!model.shouldOfferSubscription)
    }

    @Test("Refreshing re-reads the engine rather than caching a verdict")
    func refreshRereads() {
        let entitlements = store(startedDaysAgo: 1)
        let model = EntitlementModel(entitlements: entitlements, service: nil)
        #expect(model.allowsNewWork)

        _ = entitlements.record(subscription: .init(
            productID: SubscriptionProducts.monthly,
            period: .monthly,
            expires: Date().addingTimeInterval(30 * 86_400)))
        model.refresh()

        #expect(model.state.name == "subscribed")
    }

    // ── Product identifiers ─────────────────────────────────────────────────

    @Test("The product identifiers map to the periods the engine records")
    func productIdentifiersMap() {
        // These strings have to match App Store Connect and the Play Console
        // exactly, and they are the same two on both so the engine's record
        // means the same thing wherever it was written.
        #expect(SubscriptionProducts.period(of: SubscriptionProducts.monthly) == .monthly)
        #expect(SubscriptionProducts.period(of: SubscriptionProducts.yearly) == .yearly)
        #expect(SubscriptionProducts.period(of: "voxscripta.weekly") == nil)
        #expect(SubscriptionProducts.all.count == 2)
    }

    // ── The one number this screen computes ─────────────────────────────────

    @Test("The saving is computed from the real prices")
    func savingIsComputed() {
        // A hardcoded percentage becomes a false advertisement the first time
        // either price moves — and in a currency whose tiers round
        // differently, it can be false on the day it ships.
        let note = StoreKitSubscriptionService.saving(yearly: 29.99, monthly: 3.99)
        #expect(note == "Save 37%")
    }

    @Test("No saving is claimed when there is none")
    func noFalseSaving() {
        // Yearly priced at or above twelve months of monthly.
        #expect(StoreKitSubscriptionService.saving(yearly: 47.88, monthly: 3.99) == nil)
        #expect(StoreKitSubscriptionService.saving(yearly: 60.00, monthly: 3.99) == nil)
    }

    @Test("A trivial saving is not advertised")
    func trivialSavingIsSilent() {
        // Under 5% is noise, and "Save 2%" invites the arithmetic rather than
        // the purchase.
        #expect(StoreKitSubscriptionService.saving(yearly: 46.99, monthly: 3.99) == nil)
    }

    @Test("A saving cannot be computed without a monthly price")
    func savingNeedsBothPrices() {
        #expect(StoreKitSubscriptionService.saving(yearly: 29.99, monthly: nil) == nil)
        #expect(StoreKitSubscriptionService.saving(yearly: 29.99, monthly: 0) == nil)
    }

    // ── What is not wired ───────────────────────────────────────────────────

    @Test("This build sells nothing, and the engine walls anyway")
    func noStoreIsConfigured() {
        // The honest state, asserted so it is a decision rather than
        // something forgotten. Two things outside the code are missing: the
        // products in App Store Connect, and the public Terms of Use and
        // Privacy Policy URLs that Guideline 3.1.2 requires on the paywall.
        #expect(configuredSubscriptionService() == nil)
    }

    @Test("A cancelled purchase is flagged rather than described")
    func cancellationIsFlagged() {
        // Backing out of the App Store sheet is not a failure, and the
        // paywall checks this flag rather than matching on wording.
        let cancelled = SubscriptionError("Cancelled.", wasCancelled: true)
        #expect(cancelled.wasCancelled)
        #expect(!SubscriptionError("The payment was declined.").wasCancelled)
    }
}
