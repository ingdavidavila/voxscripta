import Foundation
import VoxVerbaCore

/// Streams a source file into the canonical 16 kHz mono float PCM representation.
///
/// This runs exactly once per project. Every later stage memory-maps the result
/// rather than decoding again, which is what keeps a six-hour recording from ever
/// existing in RAM (§21).
///
/// - Note: Phase 1 implements this over `AVAudioFile` + `AVAudioConverter` with a
///   fixed 10-second buffer, so peak footprint is independent of source duration.
public protocol CanonicalDecoding: Sendable {
    /// Probes a source file's format without decoding it.
    func probe(url: URL) async throws -> AudioFormatDescription

    /// Decodes `url` into `destination` as raw 32-bit float samples.
    ///
    /// - Parameter progress: Called with `0...1` completion. Coalesced by the caller.
    /// - Returns: The number of canonical samples written.
    func decode(
        url: URL,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> Int64
}

/// Phase 1 implementation site.
public struct CanonicalDecoder: CanonicalDecoding {
    public init() {}

    public func probe(url: URL) async throws -> AudioFormatDescription {
        throw VoxVerbaError.notImplemented("CanonicalDecoder.probe — Phase 1")
    }

    public func decode(
        url: URL,
        to destination: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> Int64 {
        throw VoxVerbaError.notImplemented("CanonicalDecoder.decode — Phase 1")
    }
}
