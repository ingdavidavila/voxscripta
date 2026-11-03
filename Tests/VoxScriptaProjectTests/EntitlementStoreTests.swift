import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaProject

/// The trial record on disk.
///
/// The rules are tested in `EntitlementTests`; what matters here is that the
/// record survives, that the high-water mark is actually written — a mark that
/// is never saved is no defence at all — and that the gate refuses the right
/// actions and nothing else.
@Suite("Entitlement store")
struct EntitlementStoreTests {

    private func temporaryLocation() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "voxscripta-entitlement-\(UUID().uuidString)")
            .appending(path: "entitlement.json")
    }

    private let start = Date(timeIntervalSince1970: 1_762_000_000)

    @Test("The first run starts the trial and writes it down")
    func firstRunStartsTheTrial() throws {
        let location = temporaryLocation()
        let store = EntitlementStore(location: location)

        let state = store.state(now: start)
        #expect(state.name == "trialing")
        #expect(state.trialDaysRemaining == 3)
        #expect(FileManager.default.fileExists(atPath: location.path))
    }

    @Test("A second run does not restart the trial")
    func secondRunContinues() throws {
        let location = temporaryLocation()

        _ = EntitlementStore(location: location).state(now: start)
        // A separate instance, as a separate launch of the app would be.
        let later = EntitlementStore(location: location)
            .state(now: start.addingTimeInterval(2 * 86_400))

        #expect(later.trialDaysRemaining == 1)
    }

    @Test("The high-water mark is persisted, so a clock rollback survives a relaunch")
    func rollbackSurvivesRelaunch() throws {
        let location = temporaryLocation()

        _ = EntitlementStore(location: location).state(now: start)
        // Day two, recorded.
        _ = EntitlementStore(location: location).state(now: start.addingTimeInterval(2 * 86_400))

        // Clock wound back, app relaunched. Without the mark on disk this
        // hands back two days.
        let rolledBack = EntitlementStore(location: location).state(now: start)
        #expect(rolledBack.trialDaysRemaining == 1)
    }

    @Test("The trial runs out, and stays out")
    func expires() throws {
        let location = temporaryLocation()
        _ = EntitlementStore(location: location).state(now: start)

        let store = EntitlementStore(location: location)
        let after = store.state(now: start.addingTimeInterval(Entitlement.trialLength))
        #expect(after.name == "trialExpired")
        #expect(!after.allowsNewWork)
    }

    @Test("Reading twice at the same instant does not rewrite the file")
    func idempotentReads() throws {
        let location = temporaryLocation()
        let store = EntitlementStore(location: location)

        _ = store.state(now: start)
        let firstWrite = try modified(location)
        _ = store.state(now: start)

        // A running job polls this; rewriting the file on every poll would be
        // a write amplification bug with nothing to show for it.
        #expect(try modified(location) == firstWrite)
    }

    @Test("A recorded subscription outlives the process")
    func subscriptionPersists() throws {
        let location = temporaryLocation()
        _ = EntitlementStore(location: location).state(now: start)

        let state = EntitlementStore(location: location).record(
            subscription: .init(
                productID: "voxscripta.yearly", period: .yearly,
                expires: start.addingTimeInterval(365 * 86_400)),
            now: start)
        #expect(state.name == "subscribed")

        // Well past the trial, in a fresh instance.
        let later = EntitlementStore(location: location)
            .state(now: start.addingTimeInterval(100 * 86_400))
        #expect(later.allowsNewWork)
        #expect(later.name == "subscribed")
    }

    @Test("Clearing a subscription does not hand back a spent trial")
    func clearingDoesNotRestoreTheTrial() throws {
        let location = temporaryLocation()
        let store = EntitlementStore(location: location)
        _ = store.state(now: start)
        _ = store.record(
            subscription: .init(productID: "voxscripta.monthly", period: .monthly),
            now: start)

        // A refund, or a restore that found nothing, long after the trial.
        let after = store.clearSubscription(now: start.addingTimeInterval(90 * 86_400))
        #expect(after.name == "trialExpired")
    }

    @Test("Subscribing during the trial, then cancelling, is reported as a lapse")
    func cancelAfterSubscribing() throws {
        let store = EntitlementStore(location: temporaryLocation())
        _ = store.state(now: start)
        let expires = start.addingTimeInterval(30 * 86_400)
        _ = store.record(
            subscription: .init(
                productID: "voxscripta.monthly", period: .monthly, expires: expires),
            now: start)

        let after = store.state(now: expires.addingTimeInterval(1))
        #expect(after.name == "subscriptionLapsed")
        #expect(!after.allowsNewWork)
    }

    // ── The gate ────────────────────────────────────────────────────────────

    @Test("The gate lets work through during the trial")
    func gateOpenDuringTrial() throws {
        let store = EntitlementStore(location: temporaryLocation())
        _ = store.state(now: start)
        for action in GatedAction.allCases {
            try store.require(action, now: start)
        }
    }

    @Test("The gate refuses work once the trial has ended, and says why")
    func gateClosedAfterTrial() throws {
        let location = temporaryLocation()
        _ = EntitlementStore(location: location).state(now: start)
        let store = EntitlementStore(location: location)
        let afterward = start.addingTimeInterval(Entitlement.trialLength + 1)

        for action in GatedAction.allCases {
            let thrown = #expect(throws: VoxScriptaError.self) {
                try store.require(action, now: afterward)
            }
            guard case .notEntitled(let reason) = thrown else {
                Issue.record("expected notEntitled, got \(String(describing: thrown))")
                continue
            }
            // The refusal has to say the existing work is still reachable, or
            // the user reasonably assumes it is gone.
            #expect(reason.contains("exported"))
        }
    }

    @Test("A refusal is not retryable")
    func refusalIsNotRetryable() {
        // The scheduler must not loop on a paywall.
        let error = VoxScriptaError.notEntitled(reason: "no")
        #expect(!error.isRetryable)
    }

    // ── Damaged records ─────────────────────────────────────────────────────

    @Test("An unreadable record starts a new trial rather than refusing service")
    func corruptRecordIsForgiving() throws {
        let location = temporaryLocation()
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: location)

        // Deleting the file already restarts the trial, so refusing here would
        // punish a disk fault without closing any hole.
        let state = EntitlementStore(location: location).state(now: start)
        #expect(state.name == "trialing")
    }

    @Test("A record claiming a high-water mark before its first launch cannot buy an eternal trial")
    func handEditedRecordIsClamped() throws {
        let location = temporaryLocation()
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        try Data("""
            {"firstSeen":"\(formatter.string(from: start))",
             "highWater":"\(formatter.string(from: start.addingTimeInterval(-10 * 365 * 86_400)))"}
            """.utf8).write(to: location)

        let store = EntitlementStore(location: location)
        #expect(store.state(now: start).trialDaysRemaining == 3)
        // And it still ends on time.
        #expect(!store.state(now: start.addingTimeInterval(Entitlement.trialLength)).allowsNewWork)
    }

    @Test("A debug override forces a state, and is compiled out of release builds")
    func debugOverrideExists() throws {
        // Asserted so the override's existence is a decision with a test on
        // it. In a release build this function does not exist at all, which is
        // the only thing that makes an env-var unlock acceptable.
        #if DEBUG
        #expect(EntitlementStore.debugOverride() == nil,
                "VOXSCRIPTA_ENTITLEMENT must not be set while the suite runs")
        #endif
    }

    private func modified(_ url: URL) throws -> Date {
        try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date
    }
}
