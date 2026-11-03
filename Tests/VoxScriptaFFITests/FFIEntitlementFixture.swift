import Foundation
import VoxScriptaCore
import VoxScriptaProject
@testable import VoxScriptaFFI

/// Keeps the paywall out of the way of every test that is not about it.
///
/// `vs_job_start` and `vs_recording_start` now consult the trial record, so
/// without this the FFI suite would pass on a machine whose trial is young and
/// fail on the same machine three days later — a test that measures the
/// calendar rather than the code.
///
/// The process-global store is pointed once at a temporary record, which is
/// therefore always a fresh trial. It is set exactly once, through a `static
/// let`, so suites running in parallel cannot race: they all ask for the same
/// value and the first one to arrive computes it.
///
/// Tests that *are* about the wall do not come here. They call
/// `jobStart(_:_:_:gate:)` and `recordingStart(_:gate:)` with a store of their
/// own, so an expired record never becomes something another test can observe.
enum FFIEntitlementFixture {

    static func useAFreshTrial() { _ = ready }

    private static let ready: Void = {
        entitlements = EntitlementStore(location: location())
    }()

    /// A record in its own directory, so a stale one cannot be inherited.
    static func location() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "voxscripta-ffi-entitlement-\(UUID().uuidString)")
            .appending(path: "entitlement.json")
    }

    /// A store whose trial has already run out.
    static func expired() -> EntitlementStore {
        let store = EntitlementStore(location: location())
        // Started four days ago, as far as the record is concerned.
        _ = store.state(now: Date().addingTimeInterval(-4 * 86_400))
        return store
    }

    /// A store with a live subscription.
    static func subscribed(period: BillingPeriod = .monthly) -> EntitlementStore {
        let store = EntitlementStore(location: location())
        _ = store.state(now: Date().addingTimeInterval(-40 * 86_400))
        _ = store.record(subscription: .init(
            productID: "voxscripta.\(period.rawValue)",
            period: period,
            expires: Date().addingTimeInterval(20 * 86_400)))
        return store
    }
}
