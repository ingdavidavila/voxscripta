import Foundation

/// Who may start new work: the three-day trial, and the subscription after it.
///
/// In the engine, and pure, for the same reason ``PasswordPolicy`` is: both
/// interfaces and every platform have to agree on when the third day ends. A
/// trial clock that lived in the Flutter app and again in the SwiftUI app
/// would disagree about daylight saving, about a machine that slept through
/// the deadline, and about a clock that moved backwards — and the user would
/// be right to call every one of those a bug.
///
/// Nothing here touches the filesystem, the network or the clock on its own.
/// `now` is always a parameter, which is what makes the rules testable at the
/// boundaries that matter: the instant the trial ends, the instant a
/// subscription lapses, and the moment somebody moves the clock.
///
/// ## What the wall blocks
///
/// Starting new work — a transcription job, a recording. Not reading, not
/// exporting, not deleting, and not settings. A user who recorded an
/// interview during the trial can still read it, copy it and save it out
/// afterwards. Holding somebody's own words hostage behind a payment is a
/// different product from charging them to make more, and the brief is
/// explicit that the original audio is never touched.
public enum Entitlement {

    /// Three days, as asked. Expressed in seconds because that is what the
    /// arithmetic is done in; see ``trialDays`` for the number to show.
    public static let trialLength: TimeInterval = 3 * 24 * 60 * 60

    public static let trialDays = 3

    // ── The rules ───────────────────────────────────────────────────────────

    /// What this machine is entitled to at `now`.
    ///
    /// A live subscription wins over the trial clock, so somebody who
    /// subscribes on day one is not told the trial is still running, and
    /// somebody whose subscription lapses on day five is told *that* rather
    /// than being handed a trial that ended long ago.
    public static func state(of record: EntitlementRecord, now: Date) -> EntitlementState {
        if let subscription = record.subscription {
            if subscription.isActive(at: now) {
                return .subscribed(period: subscription.period, through: subscription.through)
            }
            // A lapse is reported from the moment access actually ended, which
            // is the end of any grace the store granted, not the billing date.
            return .subscriptionLapsed(since: subscription.accessEnded ?? now)
        }

        let remaining = trialRemaining(of: record, now: now)
        return remaining > 0 ? .trialing(remaining: remaining) : .trialExpired
    }

    /// How much trial is left, in seconds, never negative.
    ///
    /// Measured against the latest instant this machine has ever reported,
    /// not against `now`. Moving the clock back therefore buys nothing: the
    /// trial neither extends nor restarts. Moving it *forward* spends the
    /// trial, and permanently, which is the direction it is safe to be wrong
    /// in — the only person harmed is whoever did it.
    public static func trialRemaining(of record: EntitlementRecord, now: Date) -> TimeInterval {
        let effectiveNow = max(now, record.highWater)
        let elapsed = max(0, effectiveNow.timeIntervalSince(record.firstSeen))
        return max(0, trialLength - elapsed)
    }

    /// Whether `action` is allowed in `state`.
    ///
    /// Only the actions in ``GatedAction`` are ever refused; see the type's own
    /// documentation for what is deliberately absent from it.
    public static func permits(_ action: GatedAction, in state: EntitlementState) -> Bool {
        switch state {
        case .trialing, .subscribed:
            return true
        case .trialExpired, .subscriptionLapsed:
            // Every gated action is refused together. There is no half-wall:
            // being allowed to record but not to transcribe would leave audio
            // the app cannot do anything with.
            _ = action
            return false
        }
    }

    /// Why an action was refused, in plain English.
    ///
    /// The engine supplies the sentence because the engine is what the C ABI
    /// hands to Flutter, and a Dart caller cannot reach `VoxScriptaUI`'s
    /// localized strings. An interface that *can* localize should, and should
    /// key off ``EntitlementState`` rather than off this wording.
    public static func refusal(for state: EntitlementState) -> String? {
        switch state {
        case .trialing, .subscribed:
            return nil
        case .trialExpired:
            return "The \(trialDays)-day trial has ended. Subscribe to transcribe "
                + "and record again. Everything already transcribed stays "
                + "readable and can still be exported."
        case .subscriptionLapsed:
            return "The subscription has lapsed, so new transcriptions and "
                + "recordings are paused. Everything already transcribed stays "
                + "readable and can still be exported."
        }
    }

    // ── Keeping the record honest ───────────────────────────────────────────

    /// The record to store after observing the clock at `now`.
    ///
    /// Call this on every check and write the result back. It is what moves
    /// ``EntitlementRecord/highWater`` forward, and so it is the whole of the
    /// defence against a clock set backwards. It never moves it back.
    public static func observing(_ record: EntitlementRecord, now: Date) -> EntitlementRecord {
        var updated = record
        updated.highWater = max(record.highWater, now)
        return updated
    }

    /// The record for a machine seen for the first time at `now`.
    public static func beginning(at now: Date) -> EntitlementRecord {
        EntitlementRecord(firstSeen: now, highWater: now, subscription: nil)
    }
}

/// An action the wall can refuse.
///
/// Deliberately short, and deliberately missing: opening a project, reading
/// any transcript variant, copying it, exporting it in any format, reviewing
/// which polish edits were accepted, deleting a project, and every setting.
/// None of those is ever refused for payment. They are the user's own work and
/// the user's own disk.
public enum GatedAction: String, Codable, Hashable, Sendable, CaseIterable {
    /// Transcribing — a new job, or resuming an unfinished one.
    case startJob
    /// Recording audio in the app.
    case startRecording
}

/// How the subscription is billed.
public enum BillingPeriod: String, Codable, Hashable, Sendable, CaseIterable {
    case monthly
    case yearly
}

/// What the engine holds about this machine's trial and subscription.
///
/// `firstSeen` is written once and never again. `highWater` is the latest
/// instant the machine has ever reported, and only ever increases.
public struct EntitlementRecord: Codable, Hashable, Sendable {
    public var firstSeen: Date
    public var highWater: Date
    public var subscription: Subscription?

    public init(firstSeen: Date, highWater: Date, subscription: Subscription? = nil) {
        self.firstSeen = firstSeen
        self.highWater = max(highWater, firstSeen)
        self.subscription = subscription
    }

    /// A subscription the platform has already verified.
    ///
    /// The engine does not and cannot check this itself: on iOS the proof is a
    /// StoreKit 2 transaction signed by Apple, on Android a Play Billing
    /// purchase, and on Windows or Linux whatever the direct sale uses. Each
    /// is verified on the platform side and the result recorded here. So this
    /// type is a statement of what was verified, not evidence — which is worth
    /// being blunt about, because it means the wall is exactly as strong as
    /// the platform code that writes to it.
    public struct Subscription: Codable, Hashable, Sendable {
        /// The store's product identifier, kept so a receipt can be traced
        /// back and so a price change does not look like a different account.
        public var productID: String
        public var period: BillingPeriod

        /// When paid access ends. Nil when the store did not say — which
        /// happens in sandbox and for a non-expiring purchase — and is then
        /// treated as open-ended.
        public var expires: Date?

        /// When store-granted billing-retry grace ends, if any.
        ///
        /// Apple and Google both keep a lapsed payer in service for a while
        /// while they retry the card. Honouring it is not generosity; a
        /// subscriber whose bank declined one charge should not lose the app
        /// mid-interview.
        public var graceUntil: Date?

        public init(
            productID: String,
            period: BillingPeriod,
            expires: Date? = nil,
            graceUntil: Date? = nil
        ) {
            self.productID = productID
            self.period = period
            self.expires = expires
            self.graceUntil = graceUntil
        }

        /// The last instant this subscription grants access, or nil for
        /// open-ended.
        public var through: Date? {
            switch (expires, graceUntil) {
            case (nil, nil): return nil
            case (let expires?, nil): return expires
            case (nil, let grace?): return grace
            case (let expires?, let grace?): return max(expires, grace)
            }
        }

        public func isActive(at now: Date) -> Bool {
            guard let through else { return true }
            return now <= through
        }

        /// When access ended, for reporting a lapse.
        var accessEnded: Date? { through }
    }
}

/// What this machine may do, and for how much longer.
public enum EntitlementState: Hashable, Sendable {
    /// The trial is running, with `remaining` seconds left.
    case trialing(remaining: TimeInterval)
    /// The trial ran out and nothing was bought.
    case trialExpired
    /// Paid up. `through` is when access ends, or nil for open-ended.
    case subscribed(period: BillingPeriod, through: Date?)
    /// Paid once, not any more. `since` is when access actually ended.
    case subscriptionLapsed(since: Date)

    /// Whether new transcriptions and recordings may start.
    public var allowsNewWork: Bool {
        Entitlement.permits(.startJob, in: self)
    }

    /// Whether the interface should be showing a way to pay.
    ///
    /// True through the trial as well, because a wall that appears for the
    /// first time on the morning of day four, with no warning, reads as a
    /// bait-and-switch.
    public var shouldOfferSubscription: Bool {
        switch self {
        case .trialing, .trialExpired, .subscriptionLapsed: return true
        case .subscribed: return false
        }
    }

    /// Whole days left in the trial, rounded up, for showing a count.
    ///
    /// Rounded up so that the last few hours read as "1 day left" rather than
    /// "0 days left" while the app still works.
    public var trialDaysRemaining: Int? {
        guard case .trialing(let remaining) = self else { return nil }
        return Int((remaining / 86_400).rounded(.up))
    }

    /// A stable name for the ABI and for tests, so neither keys off wording.
    public var name: String {
        switch self {
        case .trialing: return "trialing"
        case .trialExpired: return "trialExpired"
        case .subscribed: return "subscribed"
        case .subscriptionLapsed: return "subscriptionLapsed"
        }
    }
}
