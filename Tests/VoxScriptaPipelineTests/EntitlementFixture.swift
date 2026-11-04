import Foundation
import VoxScriptaProject

/// A trial record the tests own.
///
/// `JobRunner` consults the paywall before it does anything, so without this
/// every pipeline test would pass on a machine whose trial is young and fail
/// on the same machine three days later. A fresh record in a temporary
/// directory is always inside its trial, which keeps the suite measuring the
/// code rather than the calendar.
///
/// Tests about the wall itself do not come here — they build a store with the
/// state they want.
enum EntitlementFixture {
    static func freshTrial() -> EntitlementStore {
        EntitlementStore(location: FileManager.default.temporaryDirectory
            .appending(path: "voxscripta-pipeline-entitlement-\(UUID().uuidString)")
            .appending(path: "entitlement.json"))
    }
}
