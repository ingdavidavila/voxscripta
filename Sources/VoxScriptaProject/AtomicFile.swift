import Foundation
import VoxScriptaCore

/// Durable, all-or-nothing file writes.
///
/// Every artifact in a project is written this way: to a temporary file in the
/// same directory, flushed to disk, then renamed into place. `rename(2)` within a
/// filesystem is atomic, so a reader — including the resume planner after a power
/// loss — never observes a half-written file.
///
/// The `fsync` is not optional. Without it the rename can reach disk before the
/// data does, which produces a file that exists, has the right name, and contains
/// garbage. That is strictly worse than a missing file, because the resume planner
/// would treat it as valid.
public enum AtomicFile {

    /// Writes `data` to `url`, replacing any existing file.
    public static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporary, options: [.atomic])
            try fsyncFile(at: temporary)
            try moveIntoPlace(temporary, onto: url)
            try fsyncDirectory(at: directory)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Encodes `value` as JSON and writes it atomically.
    public static func writeJSON(
        _ value: some Encodable,
        to url: URL,
        formatting: JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys]
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .iso8601
        do {
            try write(try encoder.encode(value), to: url)
        } catch let error as VoxScriptaError {
            throw error
        } catch {
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Reads and decodes JSON written by ``writeJSON(_:to:formatting:)``.
    public static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw VoxScriptaError.projectCorrupt(
                reason: "\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
        }
    }

    /// Moves `temporary` onto `destination`, replacing it if it is there.
    ///
    /// `rename(2)`, which is what the note at the top of this type has always
    /// claimed happens here. It did not: this called
    /// `FileManager.replaceItemAt`, and on swift-corelibs-foundation that
    /// throws "The file doesn't exist" when the *destination* is absent.
    /// Darwin's implementation moves the file into place either way, so on a
    /// Mac the difference never showed — while on Linux every first write of
    /// a manifest, a peaks file or a transcript failed and only overwrites
    /// worked. Found by the Linux run, where it accounted for about sixty of
    /// the sixty-two failures.
    ///
    /// One call on both platforms now, rather than a Linux branch around a
    /// Darwin-shaped call: `rename(2)` replaces an existing destination
    /// silently, succeeds when there is none, and is atomic within a
    /// filesystem — which is the guarantee the resume planner is owed and the
    /// reason ``fsyncDirectory(at:)`` below is worth making.
    private static func moveIntoPlace(_ temporary: URL, onto destination: URL) throws {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        if rename(temporary.path, destination.path) != 0 {
            throw VoxScriptaError.ioFailure(
                path: destination.path,
                reason: String(cString: strerror(errno)))
        }
        #else
        // Windows, where `rename` refuses an existing destination outright, so
        // the two cases are separated by hand. Not atomic when the file is
        // already there — the gap is the same one the directory flush below
        // records, and closing both means `MoveFileEx` with
        // MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH through WinSDK.
        // Untested: nothing here has been run on Windows yet.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        #endif
    }

    /// Flushes a file's contents to stable storage.
    private static func fsyncFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        #if canImport(Darwin)
        // F_FULLFSYNC asks the drive to flush its own write cache too. On macOS a
        // plain fsync(2) can return before the data is durable.
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1 {
            try handle.synchronize()
        }
        #else
        // No F_FULLFSYNC outside Darwin, and none is needed for the same
        // reason: fsync(2) on Linux is already specified to flush the write
        // cache, which is exactly the guarantee macOS withholds from it.
        try handle.synchronize()
        #endif
    }

    /// Flushes a directory entry, so the rename itself is durable.
    ///
    /// POSIX only, and not because the call is unavailable on Windows but
    /// because the idea is: a directory cannot be opened as a file handle
    /// there, and NTFS offers no equivalent of flushing one. The durable
    /// rename Windows does offer is `MoveFileEx` with `MOVEFILE_WRITE_THROUGH`,
    /// which is a property of the *move* rather than a separate flush — and
    /// `FileManager` does not expose it, so reaching it means replacing the
    /// rename in ``write(_:to:)`` with a `WinSDK` call.
    ///
    /// Until that is done the gap is real and is stated rather than papered
    /// over: on Windows the data is flushed (``fsyncFile(at:)`` above still
    /// runs) but the rename itself may reach disk out of order after a power
    /// loss. The failure that allows is a project missing its newest artifact,
    /// not a half-written one, because the data flush is the part that is kept.
    private static func fsyncDirectory(at url: URL) throws {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fsync(descriptor)
        #endif
    }
}

/// Content hashing for invalidation.
public enum ContentHash {
    /// SHA-256 of a file's contents, streamed so a 4 GB source is not read into memory.
    public static func file(at url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw VoxScriptaError.sourceUnavailable(path: url.path)
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256Streaming()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 {
                throw VoxScriptaError.ioFailure(path: url.path, reason: "read failed")
            }
            if read == 0 { break }
            hasher.update(buffer, count: read)
        }
        return hasher.finalize()
    }

    /// SHA-256 of a string, for parameter hashes.
    public static func string(_ text: String) -> String {
        var hasher = SHA256Streaming()
        var bytes = Array(text.utf8)
        hasher.update(&bytes, count: bytes.count)
        return hasher.finalize()
    }
}
