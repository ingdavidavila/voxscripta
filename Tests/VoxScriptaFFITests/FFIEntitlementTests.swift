import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaProject
@testable import VoxScriptaFFI

/// The paywall at the ABI boundary.
///
/// Each test owns its own record, so none of them can change what another
/// test sees. That is the whole reason the two gated entry points take their
/// gate as a parameter — see `jobStart(_:_:_:gate:)`.
@Suite("FFI entitlement")
struct FFIEntitlementTests {

    // ── Starting work ───────────────────────────────────────────────────────

    @Test("A fresh trial lets a job past the wall")
    func trialAllowsAJob() throws {
        let gate = EntitlementStore(location: FFIEntitlementFixture.location())
        _ = gate.state()

        // -3 is the wall; any other refusal is about the arguments, which is
        // what this asserts it got past.
        let handle = "".withCString { audio in
            "".withCString { project in
                jobStart(audio, project, nil, gate: gate)
            }
        }
        #expect(handle == -2, "expected the empty-path refusal, not the paywall")
    }

    @Test("An expired trial refuses a job with -3")
    func expiredRefusesAJob() throws {
        let gate = FFIEntitlementFixture.expired()
        let audio = FileManager.default.temporaryDirectory.appending(path: "a.wav").path
        let project = FileManager.default.temporaryDirectory
            .appending(path: "p.voxscripta").path

        let handle = audio.withCString { a in
            project.withCString { p in jobStart(a, p, nil, gate: gate) }
        }
        #expect(handle == -3)
    }

    @Test("The refusal says what ended and what still works")
    func refusalExplainsItself() throws {
        let gate = FFIEntitlementFixture.expired()
        _ = "/tmp/a.wav".withCString { a in
            "/tmp/p.voxscripta".withCString { p in jobStart(a, p, nil, gate: gate) }
        }

        let message = try #require(vs_last_error_copy())
        defer { vs_string_free(message) }
        let text = String(cString: message)
        #expect(text.contains("trial"))
        // A user told only "no" assumes their transcripts are gone with it.
        #expect(text.contains("exported"))
    }

    @Test("An expired trial refuses recording with -3 too")
    func expiredRefusesRecording() throws {
        let gate = FFIEntitlementFixture.expired()
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "r-\(UUID().uuidString).m4a").path

        let handle = destination.withCString { recordingStart($0, gate: gate) }
        #expect(handle == -3)
        // And nothing was created. A wall that opens the microphone first and
        // refuses afterwards has already done the thing it refused.
        #expect(!FileManager.default.fileExists(atPath: destination))
    }

    @Test("A subscription gets past the wall after the trial is long gone")
    func subscriptionAllowsAJob() throws {
        let gate = FFIEntitlementFixture.subscribed(period: .yearly)
        let handle = "".withCString { audio in
            "".withCString { project in jobStart(audio, project, nil, gate: gate) }
        }
        #expect(handle == -2, "expected the empty-path refusal, not the paywall")
    }

    @Test("The wall is checked before the arguments are")
    func wallComesFirst() throws {
        // Both are refusals, so the order only shows in which one is reported
        // — and the paywall is the more useful answer: fixing the path would
        // not help.
        let gate = FFIEntitlementFixture.expired()
        #expect(jobStart(nil, nil, nil, gate: gate) == -3)
    }

    // ── The state surface ───────────────────────────────────────────────────

    @Test("The state JSON carries every key, nulls included")
    func stateCarriesEveryKey() throws {
        let json = try #require(vs_entitlement_state())
        defer { vs_string_free(json) }
        let object = try #require(
            try JSONSerialization.jsonObject(
                with: Data(String(cString: json).utf8)) as? [String: Any])

        // A caller reading `through` to find out when a subscription ends must
        // not have to tell an omitted key from a misspelled one.
        for key in ["state", "allowsNewWork", "shouldOfferSubscription",
                    "trialDays", "trialDaysRemaining", "trialSecondsRemaining",
                    "period", "through", "lapsedSince", "refusal"] {
            #expect(object.keys.contains(key), "missing \(key)")
        }
        #expect(object["trialDays"] as? Int == 3)
    }

    @Test("A fresh record reports a running trial with three days on it")
    func freshStateIsTrialing() throws {
        let state = EntitlementWire(
            EntitlementStore(location: FFIEntitlementFixture.location()).state())
        #expect(state.state == "trialing")
        #expect(state.allowsNewWork)
        #expect(state.trialDaysRemaining == 3)
        #expect(state.shouldOfferSubscription)
        #expect(state.refusal == nil)
    }

    @Test("An expired record reports the wall and a reason")
    func expiredStateExplains() throws {
        let state = EntitlementWire(FFIEntitlementFixture.expired().state())
        #expect(state.state == "trialExpired")
        #expect(!state.allowsNewWork)
        #expect(state.trialSecondsRemaining == 0)
        #expect(state.refusal != nil)
    }

    @Test("A subscribed record names the period and stops offering to sell")
    func subscribedStateIsQuiet() throws {
        let state = EntitlementWire(
            FFIEntitlementFixture.subscribed(period: .yearly).state())
        #expect(state.state == "subscribed")
        #expect(state.period == "yearly")
        #expect(state.through != nil)
        #expect(!state.shouldOfferSubscription)
    }

    // ── Recording a purchase ────────────────────────────────────────────────

    @Test("A subscription arrives as JSON and is honoured")
    func recordsASubscription() throws {
        // Uses the process record, which the fixture has pointed at a
        // temporary file, so this does not touch the real one.
        FFIEntitlementFixture.useAFreshTrial()
        defer { _ = vs_entitlement_clear_subscription() }

        let expires = Date().addingTimeInterval(30 * 86_400).timeIntervalSince1970
        let json = """
            {"productID":"voxscripta.monthly","period":"monthly","expires":\(expires)}
            """
        #expect(json.withCString { vs_entitlement_record_subscription($0) } == 0)

        let state = try #require(vs_entitlement_state())
        defer { vs_string_free(state) }
        #expect(String(cString: state).contains("\"state\":\"subscribed\""))
    }

    @Test("An unknown billing period is refused rather than guessed")
    func unknownPeriodIsRefused() throws {
        let json = """
            {"productID":"voxscripta.weekly","period":"weekly"}
            """
        #expect(json.withCString { vs_entitlement_record_subscription($0) } == -1)
        let message = try #require(vs_last_error_copy())
        defer { vs_string_free(message) }
        #expect(String(cString: message).contains("weekly"))
    }

    @Test("Nothing at all is refused rather than treated as a purchase")
    func emptyPurchaseIsRefused() {
        #expect(vs_entitlement_record_subscription(nil) == -1)
        #expect("".withCString { vs_entitlement_record_subscription($0) } == -1)
    }

    @Test("A malformed purchase is refused")
    func malformedPurchaseIsRefused() {
        #expect("{not json".withCString { vs_entitlement_record_subscription($0) } == -1)
    }
}
