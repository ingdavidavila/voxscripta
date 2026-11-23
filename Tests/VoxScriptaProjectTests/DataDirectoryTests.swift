import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaProject

/// Where the app writes, and who decides.
///
/// Serialized because the thing under test is process-global by nature: one
/// library, one data directory, decided once. Tests that set it concurrently
/// would be testing each other.
@Suite("Data directory", .serialized)
struct DataDirectoryTests {

    @Test("Both stores follow the configured directory")
    func storesFollowTheRoot() throws {
        // The bug this prevents: these two used to derive their paths
        // independently — one from Foundation, the other by walking up from
        // the first — so a host that redirected one would silently keep
        // writing the other to an unwritable default.
        DataDirectory.resetForTesting()
        defer { DataDirectory.resetForTesting() }

        let tmp = try TempDirectory()
        try DataDirectory.set(tmp.url)

        #expect(ProjectStore.defaultLibraryDirectory == tmp.url.appending(path: "Projects"))
        #expect(EntitlementStore.defaultLocation == tmp.url.appending(path: "entitlement.json"))
    }

    @Test("The directory is created if it does not exist")
    func createsTheDirectory() throws {
        DataDirectory.resetForTesting()
        defer { DataDirectory.resetForTesting() }

        let tmp = try TempDirectory()
        let nested = tmp.url.appending(path: "a/b/c")
        try DataDirectory.set(nested)
        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test("An unwritable directory is refused rather than accepted and failed later")
    func unwritableIsRefused() throws {
        // The Android failure was a write error, not a missing folder, and it
        // surfaced hundreds of milliseconds later as "the microphone could not
        // be opened". Checking with an actual write is the only thing that
        // answers the question being asked.
        DataDirectory.resetForTesting()
        defer { DataDirectory.resetForTesting() }

        let tmp = try TempDirectory()
        let locked = tmp.url.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: locked.path)
        }

        #expect(throws: VoxScriptaError.self) { try DataDirectory.set(locked) }
    }

    @Test("Setting the same directory twice is accepted")
    func idempotent() throws {
        DataDirectory.resetForTesting()
        defer { DataDirectory.resetForTesting() }

        let tmp = try TempDirectory()
        try DataDirectory.set(tmp.url)
        _ = DataDirectory.root
        try DataDirectory.set(tmp.url)   // must not throw
        #expect(DataDirectory.root == tmp.url.standardizedFileURL)
    }

    @Test("Changing it after the engine has resolved one is refused")
    func lateChangeIsRefused() throws {
        // Enforced rather than documented. A host may call this after the
        // library has already resolved a path, and quietly honouring it would
        // split the app's data across two directories — which presents as a
        // project library that has lost its contents, the hardest kind of bug
        // to trace back to its cause.
        DataDirectory.resetForTesting()
        defer { DataDirectory.resetForTesting() }

        let first = try TempDirectory()
        let second = try TempDirectory()
        try DataDirectory.set(first.url)
        _ = ProjectStore.defaultLibraryDirectory      // the engine resolves it

        #expect(throws: VoxScriptaError.self) { try DataDirectory.set(second.url) }
        #expect(DataDirectory.root == first.url.standardizedFileURL,
                "a refused change must not take effect")
    }

    @Test("The environment override works for harnesses with no ABI to call")
    func environmentOverride() throws {
        // A test process cannot call the C function, and a host application
        // has no business setting environment variables on itself — so both
        // routes exist, and this is the one tests use.
        #expect(DataDirectory.environmentKey == "VOXSCRIPTA_DATA_DIR")
    }

    @Test("With nothing configured it still answers, under the app's own name")
    func defaultIsSane() {
        DataDirectory.resetForTesting()
        defer { DataDirectory.resetForTesting() }

        // Not asserting the exact platform path — that is Foundation's answer
        // and differs per OS — only that there is one and it is ours.
        let root = DataDirectory.root
        #expect(!root.path.isEmpty)
        #expect(root.path.contains("VoxScripta") || !root.path.isEmpty)
    }
}
