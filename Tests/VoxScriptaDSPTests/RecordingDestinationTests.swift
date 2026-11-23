import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaDSP

/// Where recordings are written.
///
/// Added because the Android session, having verified the data directory for
/// projects and the entitlement record, pointed out that nothing exercised the
/// recording path with it — their C driver does not record. That was a real
/// gap: `RecordingDestination` was the third call site changed and the only one
/// with no test behind it, so "all three now derive from one place" was a claim
/// about code I had read rather than code that had been run.
@Suite("Recording destination", .serialized)
struct RecordingDestinationTests {

    /// Compares two file URLs by path.
    ///
    /// `URL` equality is literal and `deletingLastPathComponent()` leaves a
    /// trailing slash, so `dir.appending("x").deletingLastPathComponent()` is
    /// not `==` to `dir` even when both name the same directory. Comparing
    /// paths with the slash trimmed is what the assertions below actually mean.
    private func samePath(_ a: URL, _ b: URL) -> Bool {
        func normalized(_ url: URL) -> String {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return normalized(a) == normalized(b)
    }

    @Test("Recordings follow the configured data directory")
    func followsTheDataDirectory() throws {
        DataDirectory.resetForTesting()
        defer { DataDirectory.resetForTesting() }

        let tmp = try TempDirectory()
        try DataDirectory.set(tmp.url)

        #if os(iOS) || os(visionOS) || os(tvOS) || os(watchOS)
        // Deliberately *not* the data directory on iOS. Recordings go to the
        // documents directory so the Files app can reach them: §5 promises the
        // original recording is always retrievable, and a file the user cannot
        // get to makes that promise hollow. Asserted rather than skipped, so
        // the exception stays a decision instead of drifting into a bug.
        let documents = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
        #expect(samePath(RecordingDestination.directory, documents.appending(path: "Recordings")))
        #expect(!RecordingDestination.directory.path.hasPrefix(tmp.url.path),
                "iOS must keep recordings reachable, not move them into app data")
        #else
        // Everywhere else the host decides, and on Android it must: the old
        // expression resolved to a read-only /home that does not exist, so
        // recordings had nowhere to go and the failure surfaced as the
        // microphone refusing to open.
        #expect(samePath(RecordingDestination.directory, tmp.url.appending(path: "Recordings")))
        #endif
    }

    @Test("A new recording path sits inside that directory")
    func newRecordingIsInside() throws {
        // The directory being right is not enough on its own — what matters is
        // that the file the recorder actually opens lands there.
        DataDirectory.resetForTesting()
        defer { DataDirectory.resetForTesting() }

        let tmp = try TempDirectory()
        try DataDirectory.set(tmp.url)

        let url = RecordingDestination.newRecordingURL(existsAt: { _ in false })
        #expect(samePath(url.deletingLastPathComponent(), RecordingDestination.directory),
                "\(url.path) is not inside \(RecordingDestination.directory.path)")
        #expect(!url.lastPathComponent.isEmpty)
    }

    @Test("Recordings, projects and the entitlement record share one root")
    func allThreeAgree() throws {
        // The property the change was for, stated once: three call sites that
        // used to derive their paths independently now give answers that agree
        // by construction rather than by coincidence.
        DataDirectory.resetForTesting()
        defer { DataDirectory.resetForTesting() }

        let tmp = try TempDirectory()
        try DataDirectory.set(tmp.url)

        #expect(DataDirectory.root == tmp.url.standardizedFileURL)
        #if !os(iOS) && !os(visionOS) && !os(tvOS) && !os(watchOS)
        #expect(samePath(RecordingDestination.directory.deletingLastPathComponent(),
                         tmp.url))
        #endif
    }
}
