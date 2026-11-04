import Foundation
import Observation
import VoxScriptaCore
import VoxScriptaProject

/// The trial and the subscription, as the interface sees them.
///
/// Reads ``EntitlementStore`` directly rather than over the C ABI, because
/// on Apple platforms the app links the engine. Same record, same rules, same
/// answers as the Flutter app gets from `vs_entitlement_state`.
@MainActor
@Observable
public final class EntitlementModel {

    public init(
        entitlements: EntitlementStore = EntitlementStore(),
        service: (any SubscriptionService)? = configuredSubscriptionService()
    ) {
        self.entitlements = entitlements
        self.service = service
        self.state = entitlements.state()
    }

    private let entitlements: EntitlementStore

    /// Nil when no store is wired. The paywall then says so rather than
    /// showing a button that cannot work.
    public let service: (any SubscriptionService)?

    public private(set) var state: EntitlementState

    /// Whether new transcriptions and recordings may start.
    public var allowsNewWork: Bool { state.allowsNewWork }

    /// Whether to show a way to subscribe. True during the trial as well: a
    /// wall that appears unannounced on the morning of day four reads as a
    /// bait-and-switch.
    public var shouldOfferSubscription: Bool { state.shouldOfferSubscription }

    public var trialDaysRemaining: Int? { state.trialDaysRemaining }

    /// Re-reads the record.
    ///
    /// Also moves the trial's high-water mark forward, which is what stops a
    /// clock set backwards from returning days already spent.
    public func refresh() {
        state = entitlements.state()
    }

    private var updates: Task<Void, Never>?

    /// Starts watching for renewals and refunds, and re-reads on a timer.
    ///
    /// The timer exists for one moment: the third day ending while the app is
    /// open. Without it the banner would say "1 day left" until the next
    /// launch while the engine had already begun refusing — the interface and
    /// the engine disagreeing about the same clock, which is exactly what one
    /// shared rule exists to prevent.
    public func start() {
        refresh()
        if let service = service as? StoreKitSubscriptionService {
            updates = service.observeTransactions()
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self else { return }
                self.refresh()
            }
        }
    }

    public func stop() {
        updates?.cancel()
        updates = nil
    }
}
