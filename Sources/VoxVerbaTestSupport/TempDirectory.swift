import Foundation

/// A scratch directory that removes itself when it goes out of scope.
///
/// Non-copyable so the cleanup in `deinit` cannot run early from a copy while
/// another reference is still using the directory.
public struct TempDirectory: ~Copyable {
    public let url: URL

    public init(prefix: String = "voxverba-tests") throws {
        url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes raw float samples as a canonical PCM file inside this directory.
    public func writeCanonical(_ samples: [Float], named name: String = "canonical.f32") throws -> URL {
        let destination = url.appending(path: name)
        try samples.withUnsafeBufferPointer {
            try Data(buffer: $0).write(to: destination)
        }
        return destination
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
