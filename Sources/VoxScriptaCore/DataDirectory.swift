import Foundation

/// Where everything this app owns is written.
///
/// There used to be no such thing: `ProjectStore.defaultLibraryDirectory`
/// asked Foundation for `.applicationSupportDirectory` and that was the whole
/// policy. It is the right answer on macOS and iOS and a wrong one on Android,
/// where it resolves to `/home/.local/share` — a path that does not exist, on a
/// filesystem that is read-only. The Android session found it the hard way: the
/// library screen displayed that path verbatim, and tapping Record reported
/// that the microphone could not be opened, when what had actually failed was
/// a write to a read-only volume.
///
/// So the host gets to say. On Android the native side knows its own private
/// files directory and nothing else does; the same will be true of any
/// sandboxed container.
///
/// ## Ordering
///
/// ``set(_:)`` must happen before anything reads ``root``. That requirement
/// cannot be met by documentation alone — a library may already be loaded and
/// may already have resolved a path by the time a host thinks to configure it —
/// so it is enforced: once ``root`` has been read, setting it to a *different*
/// directory throws rather than silently splitting the app's data across two
/// locations, which would look like a project library that had lost its
/// contents.
public enum DataDirectory {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured: URL?
    nonisolated(unsafe) private static var resolved: URL?

    /// The environment override, for test harnesses and benchmarks.
    ///
    /// Kept alongside ``set(_:)`` rather than instead of it, because a test
    /// process has no C ABI to call and a host application has no business
    /// setting environment variables on itself.
    public static let environmentKey = "VOXSCRIPTA_DATA_DIR"

    /// Points every store at `url`, creating it if needed.
    ///
    /// - Throws: if the directory cannot be created or written, or if a
    ///   different directory has already been handed out.
    public static func set(_ url: URL) throws {
        let target = url.standardizedFileURL
        try lock.withLock {
            if let resolved, resolved != target {
                throw VoxScriptaError.ioFailure(
                    path: target.path,
                    reason: "the data directory was already resolved to "
                          + "\(resolved.path); set it before any other call")
            }
            try createAndVerify(target)
            configured = target
            resolved = target
        }
    }

    /// Where the app writes. Resolution order: an explicit ``set(_:)``, then
    /// `VOXSCRIPTA_DATA_DIR`, then the platform's application-support folder.
    public static var root: URL {
        lock.withLock {
            if let resolved { return resolved }
            let answer: URL
            if let configured {
                answer = configured
            } else if let raw = ProcessInfo.processInfo.environment[environmentKey],
                      !raw.isEmpty {
                answer = URL(filePath: raw).standardizedFileURL
            } else {
                answer = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appending(path: "VoxScripta")
            }
            resolved = answer
            return answer
        }
    }

    /// Forgets the resolution. For tests only, which need to point several
    /// temporary directories at the same process.
    public static func resetForTesting() {
        lock.withLock {
            configured = nil
            resolved = nil
        }
    }

    /// Creating it is not enough — a path can be creatable and unwritable, and
    /// the Android failure was a write error rather than a missing folder. So
    /// the check is a real write, which is the only thing that answers the
    /// question being asked.
    private static func createAndVerify(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw VoxScriptaError.ioFailure(
                path: url.path,
                reason: "could not create the data directory: \(error.localizedDescription)")
        }
        let probe = url.appending(path: ".voxscripta-write-probe")
        do {
            try Data([0]).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            throw VoxScriptaError.ioFailure(
                path: url.path,
                reason: "the data directory is not writable: \(error.localizedDescription)")
        }
    }
}
