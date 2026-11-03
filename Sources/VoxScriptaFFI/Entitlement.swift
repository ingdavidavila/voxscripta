import Foundation
import VoxScriptaCore
import VoxScriptaProject

/// The paywall, across the C ABI.
///
/// The gate is enforced *here*, in the engine, not in the interfaces. A
/// paywall checked only by the Flutter app is a paywall the SwiftUI app, the
/// CLI and the next platform each have to remember separately — and one of
/// them will not. `vs_job_start` and `vs_recording_start` both ask before they
/// do anything, so there is one answer to "may this user start work" and every
/// caller gets it.
///
/// Verification is the platform's job and cannot be otherwise: the proof of a
/// subscription is a StoreKit 2 transaction signed by Apple, a Play Billing
/// purchase, or whatever a direct sale on Windows issues. Each is checked on
/// that side and the result handed to `vs_entitlement_record_subscription`. So
/// this surface records what was verified; it does not verify.

/// One store for the process, because the record is about the machine.
///
/// A `var` only so the test target can point it at a record it owns instead of
/// the real one in Application Support. Nothing in the shipping code reassigns
/// it, and a release build has no way to: it is internal, not public.
nonisolated(unsafe) var entitlements = EntitlementStore()

/// Refuses `action` if the wall is up, setting the thread's last error.
///
/// Returns true when the caller should stop. `store` is a parameter so the
/// gated entry points can be tested against a record a test owns.
func entitlementRefuses(_ action: GatedAction, in store: EntitlementStore) -> Bool {
    do {
        try store.require(action)
        return false
    } catch {
        setLastError(describe(error))
        return true
    }
}

/// What this machine may do. Caller releases the string.
///
///     {"state": "trialing", "allowsNewWork": true,
///      "shouldOfferSubscription": true, "trialDays": 3,
///      "trialDaysRemaining": 2, "trialSecondsRemaining": 123456.0,
///      "period": null, "through": null, "lapsedSince": null,
///      "refusal": null}
///
/// `state` is one of `trialing`, `trialExpired`, `subscribed`,
/// `subscriptionLapsed`. Key off that rather than off `refusal`, which is
/// English prose and a fallback for callers that cannot localize.
///
/// Reading this has a side effect by design: it moves the trial's high-water
/// mark forward, which is what stops a clock set backwards from handing back
/// days already spent.
@_cdecl("vs_entitlement_state")
public func vs_entitlement_state() -> UnsafeMutablePointer<CChar>? {
    setLastError(nil)
    do {
        return copyOut(try Wire.encode(EntitlementWire(entitlements.state())))
    } catch {
        setLastError(describe(error))
        return nil
    }
}

/// Records a subscription the platform has already verified.
///
///     {"productID": "voxscripta.monthly", "period": "monthly",
///      "expires": 1764600000.0, "graceUntil": null}
///
/// `period` is `monthly` or `yearly`. `expires` and `graceUntil` are seconds
/// since 1970, or absent when the store did not say — which is then treated as
/// open-ended, so do not pass 0 to mean "unknown".
///
/// Returns 0, or -1 with `vs_last_error_copy` set.
@_cdecl("vs_entitlement_record_subscription")
public func vs_entitlement_record_subscription(
    _ subscription_json: UnsafePointer<CChar>?
) -> Int32 {
    setLastError(nil)
    let json = subscription_json.map { String(cString: $0) } ?? ""
    guard !json.isEmpty else {
        setLastError("vs_entitlement_record_subscription needs a subscription")
        return -1
    }
    do {
        guard let wire = try Wire.decode(SubscriptionWire.self, from: json) else {
            setLastError("vs_entitlement_record_subscription needs a subscription")
            return -1
        }
        guard let period = BillingPeriod(rawValue: wire.period) else {
            setLastError("unknown billing period '\(wire.period)' — expected monthly or yearly")
            return -1
        }
        _ = entitlements.record(subscription: .init(
            productID: wire.productID,
            period: period,
            expires: wire.expires.map(Date.init(timeIntervalSince1970:)),
            graceUntil: wire.graceUntil.map(Date.init(timeIntervalSince1970:))))
        return 0
    } catch {
        setLastError(describe(error))
        return -1
    }
}

/// Forgets the subscription: a refund, or a restore that found nothing.
///
/// The trial clock is untouched, so this does not hand back a trial that has
/// already been spent. Returns 0.
@_cdecl("vs_entitlement_clear_subscription")
public func vs_entitlement_clear_subscription() -> Int32 {
    setLastError(nil)
    entitlements.clearSubscription()
    return 0
}

// MARK: - Wire types

/// The entitlement, flattened for a caller with no enums.
struct EntitlementWire: Codable {
    let state: String
    let allowsNewWork: Bool
    let shouldOfferSubscription: Bool
    let trialDays: Int
    let trialDaysRemaining: Int?
    let trialSecondsRemaining: Double?
    let period: String?
    let through: Double?
    let lapsedSince: Double?
    let refusal: String?

    init(_ state: EntitlementState) {
        self.state = state.name
        self.allowsNewWork = state.allowsNewWork
        self.shouldOfferSubscription = state.shouldOfferSubscription
        self.trialDays = Entitlement.trialDays
        self.trialDaysRemaining = state.trialDaysRemaining
        self.refusal = Entitlement.refusal(for: state)

        switch state {
        case .trialing(let remaining):
            self.trialSecondsRemaining = remaining
            self.period = nil
            self.through = nil
            self.lapsedSince = nil
        case .trialExpired:
            self.trialSecondsRemaining = 0
            self.period = nil
            self.through = nil
            self.lapsedSince = nil
        case .subscribed(let period, let through):
            self.trialSecondsRemaining = nil
            self.period = period.rawValue
            self.through = through?.timeIntervalSince1970
            self.lapsedSince = nil
        case .subscriptionLapsed(let since):
            self.trialSecondsRemaining = nil
            self.period = nil
            self.through = nil
            self.lapsedSince = since.timeIntervalSince1970
        }
    }

    /// Hand-written so every key is present, null included.
    ///
    /// The synthesized encoding omits a nil optional, and a caller reading
    /// `through` to find out when a subscription ends cannot tell an omitted
    /// key from a key it spelled wrong. Same reason `AudioFactsWire` does it.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(allowsNewWork, forKey: .allowsNewWork)
        try c.encode(shouldOfferSubscription, forKey: .shouldOfferSubscription)
        try c.encode(trialDays, forKey: .trialDays)
        try c.encode(trialDaysRemaining, forKey: .trialDaysRemaining)
        try c.encode(trialSecondsRemaining, forKey: .trialSecondsRemaining)
        try c.encode(period, forKey: .period)
        try c.encode(through, forKey: .through)
        try c.encode(lapsedSince, forKey: .lapsedSince)
        try c.encode(refusal, forKey: .refusal)
    }
}

/// A verified subscription, on the way in.
struct SubscriptionWire: Codable {
    let productID: String
    let period: String
    let expires: Double?
    let graceUntil: Double?
}
