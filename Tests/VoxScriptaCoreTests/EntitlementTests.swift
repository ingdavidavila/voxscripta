import Testing
import Foundation
@testable import VoxScriptaCore

/// The three-day trial and the subscription behind it.
///
/// The interesting cases are all at boundaries: the instant the third day
/// ends, the instant a subscription lapses, and what happens when somebody
/// moves the machine's clock. Those are pinned here because the rules are
/// pure and the clock is a parameter — the whole reason this lives in the
/// engine instead of twice over in two interfaces.
@Suite("Entitlement")
struct EntitlementTests {

    private let start = Date(timeIntervalSince1970: 1_762_000_000)

    private func fresh() -> EntitlementRecord { Entitlement.beginning(at: start) }

    private func state(_ record: EntitlementRecord, after seconds: TimeInterval) -> EntitlementState {
        Entitlement.state(of: record, now: start.addingTimeInterval(seconds))
    }

    // ── The trial clock ─────────────────────────────────────────────────────

    @Test("A new machine is in the trial with all three days left")
    func startsTrialing() {
        let state = state(fresh(), after: 0)
        #expect(state.name == "trialing")
        #expect(state.allowsNewWork)
        #expect(state.trialDaysRemaining == 3)
    }

    @Test("The trial lasts until the end of the third day, and not a second less")
    func lastsThreeFullDays() {
        let record = fresh()
        let threeDays: TimeInterval = 3 * 24 * 60 * 60

        // One second before the deadline the app still works.
        #expect(state(record, after: threeDays - 1).allowsNewWork)
        // At the deadline it does not. The boundary is closed at the top, so
        // "three days" means three days and not three days plus an instant.
        #expect(!state(record, after: threeDays).allowsNewWork)
        #expect(state(record, after: threeDays).name == "trialExpired")
    }

    @Test("Days remaining round up, so the last hours do not read as zero")
    func daysRoundUp() {
        let record = fresh()
        // Half an hour left: the app works, so it must not say "0 days".
        let nearlyOver = state(record, after: Entitlement.trialLength - 1800)
        #expect(nearlyOver.allowsNewWork)
        #expect(nearlyOver.trialDaysRemaining == 1)
    }

    @Test("An expired trial reports no days remaining at all")
    func expiredHasNoCount() {
        #expect(state(fresh(), after: Entitlement.trialLength).trialDaysRemaining == nil)
    }

    // ── A clock moved backwards ─────────────────────────────────────────────

    @Test("Winding the clock back does not extend the trial")
    func rollbackBuysNothing() {
        var record = fresh()
        // Day two: the machine reports in, and the high-water mark moves.
        record = Entitlement.observing(record, now: start.addingTimeInterval(2 * 86_400))

        // Now the clock goes back to the first morning. Without the high-water
        // mark this would hand back two days of trial.
        let rolledBack = Entitlement.state(of: record, now: start.addingTimeInterval(60))
        #expect(rolledBack.trialDaysRemaining == 1)
    }

    @Test("Winding the clock back after the trial ended does not restart it")
    func rollbackDoesNotRestart() {
        var record = fresh()
        record = Entitlement.observing(record, now: start.addingTimeInterval(Entitlement.trialLength))

        let rolledBack = Entitlement.state(of: record, now: start)
        #expect(!rolledBack.allowsNewWork)
        #expect(rolledBack.name == "trialExpired")
    }

    @Test("Winding the clock forward spends the trial, and permanently")
    func rollforwardSpendsIt() {
        var record = fresh()
        // Somebody jumps a year ahead — perhaps to see what happens.
        record = Entitlement.observing(record, now: start.addingTimeInterval(365 * 86_400))
        // And comes back. The trial is gone; the only person harmed did it.
        #expect(!Entitlement.state(of: record, now: start.addingTimeInterval(60)).allowsNewWork)
    }

    @Test("Observing never moves the high-water mark backwards")
    func observingOnlyIncreases() {
        let record = Entitlement.observing(fresh(), now: start.addingTimeInterval(86_400))
        let after = Entitlement.observing(record, now: start.addingTimeInterval(-86_400))
        #expect(after.highWater == record.highWater)
    }

    @Test("A record whose high-water mark predates its first launch is corrected")
    func highWaterNeverPrecedesFirstSeen() {
        // A hand-edited or partly-written file should not produce a negative
        // elapsed time and an eternal trial.
        let record = EntitlementRecord(
            firstSeen: start, highWater: start.addingTimeInterval(-10_000))
        #expect(record.highWater == start)
        #expect(Entitlement.trialRemaining(of: record, now: start) == Entitlement.trialLength)
    }

    // ── Subscriptions ───────────────────────────────────────────────────────

    @Test("A live subscription allows work whatever the trial clock says")
    func subscriptionOutranksTrial() {
        var record = fresh()
        record.subscription = .init(
            productID: "voxscripta.monthly", period: .monthly,
            expires: start.addingTimeInterval(30 * 86_400))

        // Long after the trial would have ended.
        let state = state(record, after: 20 * 86_400)
        #expect(state.name == "subscribed")
        #expect(state.allowsNewWork)
        #expect(!state.shouldOfferSubscription)
        #expect(state.trialDaysRemaining == nil)
    }

    @Test("Somebody who subscribes on day one is not told the trial is running")
    func subscribedEarlyIsNotTrialing() {
        var record = fresh()
        record.subscription = .init(
            productID: "voxscripta.yearly", period: .yearly,
            expires: start.addingTimeInterval(365 * 86_400))
        #expect(state(record, after: 3600).name == "subscribed")
    }

    @Test("A lapsed subscription is reported as lapsed, not as an expired trial")
    func lapseIsItsOwnState() {
        var record = fresh()
        record.subscription = .init(
            productID: "voxscripta.monthly", period: .monthly,
            expires: start.addingTimeInterval(30 * 86_400))

        let state = state(record, after: 31 * 86_400)
        #expect(state.name == "subscriptionLapsed")
        #expect(!state.allowsNewWork)
        #expect(state.shouldOfferSubscription)
        // Being told "your trial ended" a month after paying would be its own
        // small insult, and would hide the real problem: a failed renewal.
        #expect(Entitlement.refusal(for: state)?.contains("subscription") == true)
    }

    @Test("Store-granted grace keeps a subscriber working past the billing date")
    func graceIsHonoured() {
        var record = fresh()
        let expires = start.addingTimeInterval(30 * 86_400)
        record.subscription = .init(
            productID: "voxscripta.monthly", period: .monthly,
            expires: expires, graceUntil: expires.addingTimeInterval(16 * 86_400))

        // The card was declined; Apple and Google are both still retrying. A
        // subscriber must not lose the app mid-interview over that.
        #expect(state(record, after: 40 * 86_400).allowsNewWork)
        #expect(!state(record, after: 47 * 86_400).allowsNewWork)
    }

    @Test("A lapse is dated from when access ended, not from the billing date")
    func lapseDatedFromGraceEnd() {
        var record = fresh()
        let expires = start.addingTimeInterval(30 * 86_400)
        let graceEnd = expires.addingTimeInterval(16 * 86_400)
        record.subscription = .init(
            productID: "voxscripta.monthly", period: .monthly,
            expires: expires, graceUntil: graceEnd)

        guard case .subscriptionLapsed(let since) = state(record, after: 60 * 86_400) else {
            Issue.record("expected a lapse")
            return
        }
        #expect(since == graceEnd)
    }

    @Test("A subscription with no stated end is open-ended")
    func noExpiryMeansOpenEnded() {
        var record = fresh()
        // Sandbox, and a non-expiring purchase, both arrive this way.
        record.subscription = .init(productID: "voxscripta.monthly", period: .monthly)
        #expect(state(record, after: 10 * 365 * 86_400).allowsNewWork)
    }

    // ── What the wall does and does not block ───────────────────────────────

    @Test("Every gated action is refused together")
    func gatedActionsMoveAsOne() {
        let expired = state(fresh(), after: Entitlement.trialLength)
        for action in GatedAction.allCases {
            #expect(!Entitlement.permits(action, in: expired))
        }
        // Being allowed to record but not to transcribe would leave the user
        // holding audio the app will not touch.
        #expect(GatedAction.allCases.count == 2)
    }

    @Test("Only starting work is gated — nothing about reading or exporting is")
    func readingIsNeverGated() {
        // The wall's whole surface, asserted so that adding to it is a
        // deliberate act with a failing test attached. Reading a transcript,
        // copying it, exporting any format, reviewing polish, deleting a
        // project and every setting are all absent on purpose.
        #expect(Set(GatedAction.allCases.map(\.rawValue)) == ["startJob", "startRecording"])
    }

    @Test("A refusal says the existing transcripts are still readable")
    func refusalReassures() {
        for state in [
            state(fresh(), after: Entitlement.trialLength),
            EntitlementState.subscriptionLapsed(since: start),
        ] {
            let reason = Entitlement.refusal(for: state)
            #expect(reason?.contains("exported") == true)
        }
    }

    @Test("Nothing is refused while the user may work")
    func noRefusalWhenAllowed() {
        #expect(Entitlement.refusal(for: state(fresh(), after: 0)) == nil)
        #expect(Entitlement.refusal(for: .subscribed(period: .yearly, through: nil)) == nil)
    }

    @Test("A way to pay is offered during the trial, not only after it")
    func offerAppearsDuringTrial() {
        // A wall that turns up for the first time on the morning of day four,
        // with no warning, reads as a bait-and-switch.
        #expect(state(fresh(), after: 0).shouldOfferSubscription)
    }

    // ── The record itself ───────────────────────────────────────────────────

    @Test("The record survives a round trip through JSON")
    func recordRoundTrips() throws {
        var record = fresh()
        record.subscription = .init(
            productID: "voxscripta.yearly", period: .yearly,
            expires: start.addingTimeInterval(365 * 86_400),
            graceUntil: start.addingTimeInterval(381 * 86_400))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let back = try decoder.decode(
            EntitlementRecord.self, from: try encoder.encode(record))
        #expect(back == record)
    }
}
