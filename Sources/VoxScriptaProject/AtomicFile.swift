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
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
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
    private static func fsyncDirectory(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fsync(descriptor)
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
