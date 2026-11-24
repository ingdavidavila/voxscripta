import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaProject
@testable import VoxScriptaUI

/// The StoreKit configuration file, held to the code that reads it.
///
/// `ios/VoxScripta.storekit` is what a debug build run from Xcode sells
/// instead of the real App Store, so the purchase flow can be exercised
/// before the products exist in App Store Connect. It is a separate file from
/// the code, in a format Xcode writes, which makes it exactly the kind of
/// thing that drifts: rename a product in one place and the paywall goes
/// quiet with no build error anywhere.
///
/// What these tests cannot do is run a purchase. `SKTestSession` needs a host
/// application with a container, and a SwiftPM test bundle has neither — it
/// runs inside `swiftpm-testing-helper`, where the session fails to write its
/// configuration. Watching money change hands therefore means launching the
/// app from Xcode, which `Docs/RELEASE.md` sets out. These tests cover the
/// part that can be checked without a simulator, which is the part that
/// drifts.
@Suite("StoreKit configuration")
struct StoreKitConfigurationTests {

    // ── Reading the file ────────────────────────────────────────────────────

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // VoxScriptaAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // the repository

    private static let configurationURL =
        repositoryRoot.appending(path: "ios/VoxScripta.storekit")

    /// One subscription as the file records it.
    private struct Subscription {
        let productID: String
        let period: String
        let type: String
        let groupID: String
        let displayPrice: String
        let introductoryOffer: Any?
        let localizations: [[String: Any]]
    }

    private static func configuration() throws -> (groupID: String, subscriptions: [Subscription], settings: [String: Any]) {
        let data = try Data(contentsOf: configurationURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let groups = try #require(root["subscriptionGroups"] as? [[String: Any]])

        // One group, deliberately: subscriptions in the same group are
        // mutually exclusive, so monthly and yearly replace one another.
        // In separate groups the same person could hold both at once.
        #expect(groups.count == 1, "monthly and yearly must share one subscription group")
        let group = try #require(groups.first)
        let groupID = try #require(group["id"] as? String)

        let raw = try #require(group["subscriptions"] as? [[String: Any]])
        let subscriptions = try raw.map { entry in
            Subscription(
                productID: try #require(entry["productID"] as? String),
                period: try #require(entry["recurringSubscriptionPeriod"] as? String),
                type: try #require(entry["type"] as? String),
                groupID: try #require(entry["subscriptionGroupID"] as? String),
                displayPrice: try #require(entry["displayPrice"] as? String),
                introductoryOffer: entry["introductoryOffer"],
                localizations: try #require(entry["localizations"] as? [[String: Any]]))
        }
        let settings = root["settings"] as? [String: Any] ?? [:]
        return (groupID, subscriptions, settings)
    }

    // ── What it has to agree with ──────────────────────────────────────────

    @Test("The file offers exactly the products the code asks the store for")
    func identifiersMatchTheCode() throws {
        let config = try Self.configuration()
        let inFile = Set(config.subscriptions.map(\.productID))
        // `products()` asks for `SubscriptionProducts.all` and nothing else.
        // An identifier in one list and not the other is a silent failure:
        // the store simply returns fewer products than the paywall expected.
        #expect(inFile == Set(SubscriptionProducts.all))
    }

    @Test("Each billing period matches the period the engine will record")
    func periodsMatchTheCode() throws {
        for subscription in try Self.configuration().subscriptions {
            let expected = SubscriptionProducts.period(of: subscription.productID)
            let fromFile: BillingPeriod? = switch subscription.period {
            case "P1M": .monthly
            case "P1Y": .yearly
            default: nil
            }
            #expect(fromFile == expected,
                    "\(subscription.productID) renews \(subscription.period)")
        }
    }

    @Test("Every product is an auto-renewing subscription in the one group")
    func allAreRecurringInOneGroup() throws {
        let config = try Self.configuration()
        for subscription in config.subscriptions {
            #expect(subscription.type == "RecurringSubscription")
            #expect(subscription.groupID == config.groupID)
        }
    }

    // ── The trial is the engine's, not the store's ─────────────────────────

    @Test("No product carries an introductory offer")
    func noIntroductoryOffer() throws {
        // The three-day trial is enforced by the engine from `firstSeen`, on
        // every platform, including the ones with no store at all. A StoreKit
        // introductory free trial would be a *second*, separate free period
        // granted per Apple Account — so someone would get three days from
        // the engine and then another week from Apple, and the Android and
        // desktop builds would silently disagree about what a trial is.
        #expect(Entitlement.trialLength == 3 * 24 * 60 * 60)
        for subscription in try Self.configuration().subscriptions {
            let offer = subscription.introductoryOffer
            let absent = offer == nil || offer is NSNull
            #expect(absent, "\(subscription.productID) has an introductory offer")
        }
    }

    // ── What a buyer would read ────────────────────────────────────────────

    @Test("Every product has a name and a description to show")
    func everyProductIsLegible() throws {
        for subscription in try Self.configuration().subscriptions {
            let english = subscription.localizations.first { $0["locale"] as? String == "en_US" }
            let localization = try #require(english,
                "\(subscription.productID) has no en_US localization")
            // The paywall shows `product.displayName` straight from the
            // store. An empty string here is a blank row, not a build error.
            let name = localization["displayName"] as? String ?? ""
            let description = localization["description"] as? String ?? ""
            #expect(!name.isEmpty)
            #expect(!description.isEmpty)
        }
    }

    @Test("The configured prices produce the saving the paywall advertises")
    func savingIsClaimableFromThesePrices() throws {
        let config = try Self.configuration()
        func price(_ id: String) throws -> Decimal {
            let entry = try #require(config.subscriptions.first { $0.productID == id })
            return try #require(Decimal(string: entry.displayPrice))
        }
        // Exercises the real computation against the real file, so a price
        // edited here cannot quietly turn the yearly plan into a worse deal
        // than twelve months of monthly while the paywall still says "Save".
        let note = StoreKitSubscriptionService.saving(
            yearly: try price(SubscriptionProducts.yearly),
            monthly: try price(SubscriptionProducts.monthly))
        #expect(note == "Save 37%")
    }

    // ── Settings that would break a test run ───────────────────────────────

    @Test("Transactions are not configured to fail")
    func transactionsAreNotRiggedToFail() throws {
        // Xcode writes this flag into the file when the "Fail Transactions"
        // switch is left on in the StoreKit editor. Committed as true, every
        // purchase fails for whoever next runs the app, and the cause is in a
        // JSON file nobody thinks to read.
        let settings = try Self.configuration().settings
        #expect(settings["_failTransactionsEnabled"] as? Bool == false)
    }

    // ── That anything uses the file at all ─────────────────────────────────

    @Test("The run scheme points at this configuration file")
    func schemeReferencesTheConfiguration() throws {
        // A configuration file no scheme names is inert, and inert in a way
        // that looks exactly like working: the paywall shows no plans,
        // which is also what it shows before App Store Connect has any.
        let scheme = Self.repositoryRoot.appending(
            path: "ios/VoxScripta.xcodeproj/xcshareddata/xcschemes/VoxScripta.xcscheme")
        let xml = try String(contentsOf: scheme, encoding: .utf8)
        #expect(xml.contains("StoreKitConfigurationFileReference"))
        #expect(xml.contains("VoxScripta.storekit"))
    }

    @MainActor
    @Test("The service is wired, and the engine still walls regardless")
    func serviceIsWired() {
        // Was nil until the configuration file existed, on the grounds that a
        // store with no products is not a store. The products are still
        // missing from App Store Connect, but returning the service means the
        // purchase path a debug build runs is the one that ships, rather than
        // code first executed on the day it can no longer be changed.
        #expect(configuredSubscriptionService() != nil)
        // Unchanged by any of this: a build with nothing for sale still stops
        // transcribing on day four. Only App Store Connect fixes that.
        let expired = EntitlementStore(location: FileManager.default.temporaryDirectory
            .appending(path: "voxscripta-storekit-\(UUID().uuidString)")
            .appending(path: "entitlement.json"))
        _ = expired.state(now: Date().addingTimeInterval(-4 * 86_400))
        #expect(!EntitlementModel(entitlements: expired).allowsNewWork)
    }
}
