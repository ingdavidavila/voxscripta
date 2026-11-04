import Foundation
import VoxScriptaCore

/// Keeps this machine's trial and subscription on disk.
///
/// ``Entitlement`` holds the rules and touches nothing; this holds the record
/// and touches the clock and the filesystem. Splitting them that way is what
/// lets every boundary in the rules be tested at an exact instant.
///
/// ## How strong this is
///
/// Not very, and deliberately not pretending otherwise. The record is a JSON
/// file in Application Support. Deleting it, or reinstalling the app, starts a
/// fresh trial; so does a new user account on the same machine. What it does
/// stop is the easy abuse — winding the clock back, which ``Entitlement``
/// handles by never letting the high-water mark move backwards.
///
/// A trial that genuinely could not be reset would have to be anchored
/// somewhere the user cannot reach: the store's own introductory-offer
/// mechanism, which needs a payment method on day zero, or a server of ours,
/// which this application does not have and whose absence is the point of it.
/// The decision was to take the leaky trial over either, and it is recorded
/// here so that nobody later mistakes the leak for an oversight.
public final class EntitlementStore: @unchecked Sendable {

    /// Where the record lives: beside the library, not inside it.
    ///
    /// Not inside a project, because it is about the machine rather than about
    /// any one recording, and a user who moved their library to an external
    /// disk should not take their trial with them.
    public static var defaultLocation: URL {
        ProjectStore.defaultLibraryDirectory
            .deletingLastPathComponent()
            .appending(path: "entitlement.json")
    }

    private let location: URL
    private let lock = NSLock()

    public init(location: URL = EntitlementStore.defaultLocation) {
        self.location = location
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    /// This machine's entitlement at `now`, creating the record on first run.
    ///
    /// Writes as a side effect: the first call ever records the start of the
    /// trial, and every call moves the high-water mark forward. That write is
    /// not optional — without it the clock defence does not exist, because a
    /// mark that is never saved is a mark that never rises.
    public func state(now: Date = Date()) -> EntitlementState {
        #if DEBUG
        if let forced = Self.debugOverride() { return forced }
        #endif
        return Entitlement.state(of: observedRecord(now: now), now: now)
    }

    /// The record as it stands, after noting that the clock reads `now`.
    public func observedRecord(now: Date = Date()) -> EntitlementRecord {
        lock.lock()
        defer { lock.unlock() }

        let existing = loadLocked()
        let record = existing.map { Entitlement.observing($0, now: now) }
            ?? Entitlement.beginning(at: now)

        // Only write when something actually changed, so a read-heavy caller
        // does not rewrite the file on every poll of a running job.
        if record != existing { saveLocked(record) }
        return record
    }

    // ── Writing ─────────────────────────────────────────────────────────────

    /// Records a subscription the platform has already verified.
    ///
    /// The engine cannot verify it and does not try: the proof is a StoreKit 2
    /// transaction on Apple platforms, a Play Billing purchase on Android, and
    /// whatever the direct sale issues on Windows and Linux. Each is checked
    /// on that side and the outcome stored here, which means the wall is
    /// exactly as strong as the platform code calling this.
    public func record(
        subscription: EntitlementRecord.Subscription,
        now: Date = Date()
    ) -> EntitlementState {
        lock.lock()
        var record = (loadLocked() ?? Entitlement.beginning(at: now))
        record = Entitlement.observing(record, now: now)
        record.subscription = subscription
        saveLocked(record)
        lock.unlock()
        return Entitlement.state(of: record, now: now)
    }

    /// Forgets the subscription — a cancellation that has run out, a refund, or
    /// a restore that found nothing.
    ///
    /// The trial clock is untouched, so this does not hand back a trial that
    /// has already been spent.
    @discardableResult
    public func clearSubscription(now: Date = Date()) -> EntitlementState {
        lock.lock()
        var record = (loadLocked() ?? Entitlement.beginning(at: now))
        record = Entitlement.observing(record, now: now)
        record.subscription = nil
        saveLocked(record)
        lock.unlock()
        return Entitlement.state(of: record, now: now)
    }

    // ── The gate ────────────────────────────────────────────────────────────

    /// Throws if `action` is walled off right now.
    ///
    /// The engine calls this at the top of the two entry points that start
    /// work. Putting it there rather than in each interface is the point: a
    /// paywall enforced only in the UI is a paywall that the other interface,
    /// the CLI and the next platform all forget.
    public func require(_ action: GatedAction, now: Date = Date()) throws {
        let state = state(now: now)
        guard !Entitlement.permits(action, in: state) else { return }
        throw VoxScriptaError.notEntitled(
            reason: Entitlement.refusal(for: state) ?? "This needs a subscription.")
    }

    // ── Disk ────────────────────────────────────────────────────────────────

    private func loadLocked() -> EntitlementRecord? {
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        do {
            return try AtomicFile.readJSON(EntitlementRecord.self, from: location)
        } catch {
            // An unreadable record starts a fresh trial rather than refusing
            // service. It is the kinder failure and it costs nothing, because
            // deleting the file already does exactly this — whereas treating a
            // disk problem as an expired trial would wall off a paying user
            // over corruption they did not cause.
            Log.project.warning(
                "entitlement record unreadable, starting a new trial: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func saveLocked(_ record: EntitlementRecord) {
        do {
            try AtomicFile.writeJSON(record, to: location)
        } catch {
            // Not fatal. The app keeps working on the record in hand; the
            // clock defence is weaker until a write succeeds.
            Log.project.warning(
                "entitlement record could not be written: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
    /// Forces a state, for working on the wall without waiting three days.
    ///
    /// `VOXSCRIPTA_ENTITLEMENT` = `trial`, `expiring`, `expired`, `subscribed`
    /// or `lapsed`. Compiled out of release builds entirely, which is the only
    /// reason it is acceptable: an environment variable that unlocked a
    /// shipping build would be the whole paywall, undone in one line by
    /// anybody who read this file.
    static func debugOverride() -> EntitlementState? {
        switch ProcessInfo.processInfo.environment["VOXSCRIPTA_ENTITLEMENT"] {
        case "trial": return .trialing(remaining: Entitlement.trialLength)
        case "expiring": return .trialing(remaining: 1800)
        case "expired": return .trialExpired
        case "subscribed": return .subscribed(period: .monthly, through: nil)
        case "lapsed": return .subscriptionLapsed(since: Date())
        default: return nil
        }
    }
    #endif
}
