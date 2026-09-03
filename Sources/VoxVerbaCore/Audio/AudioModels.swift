import Foundation

/// The format VoxVerba canonicalizes every source into before analysis.
///
/// 16 kHz mono 32-bit float is what both candidate ASR engines want, so
/// converting once at import means no stage downstream ever resamples again.
public enum CanonicalFormat {
    public static let sampleRate = 16_000
    public static let channelCount = 1
    public static let bytesPerSample = 4
    public static let fileExtension = "f32"

    /// Bytes on disk for a given duration of canonical audio.
    public static func byteCount(for duration: MediaTime) -> Int64 {
        duration.samples(at: sampleRate) * Int64(bytesPerSample)
    }
}

/// What the source file actually is, as probed at import.
public struct AudioFormatDescription: Hashable, Sendable, Codable {
    public let sampleRate: Double
    public let channelCount: Int
    public let bitDepth: Int?
    /// The container/codec as reported by AVFoundation, for display and diagnostics.
    public let formatDescription: String

    public init(sampleRate: Double, channelCount: Int, bitDepth: Int? = nil, formatDescription: String) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.formatDescription = formatDescription
    }
}

/// An imported recording.
///
/// - Important: The original file is referenced, never owned. There is no write
///   path to `bookmark` anywhere in the codebase — that is what makes the §5
///   guarantee structural rather than a matter of discipline.
public struct AudioSource: Hashable, Sendable, Codable, Identifiable {
    public let id: SourceID
    /// Security-scoped bookmark resolved read-only.
    public let bookmark: Data
    /// Display name. Not a path — the file may have moved.
    public let displayName: String
    /// SHA-256 of the file's contents, used for resume validation and de-duplication.
    public let contentHash: String
    public let format: AudioFormatDescription
    public let duration: MediaTime
    public let byteSize: Int64
    public let importedAt: Date

    public init(
        id: SourceID = SourceID(),
        bookmark: Data,
        displayName: String,
        contentHash: String,
        format: AudioFormatDescription,
        duration: MediaTime,
        byteSize: Int64,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.bookmark = bookmark
        self.displayName = displayName
        self.contentHash = contentHash
        self.format = format
        self.duration = duration
        self.byteSize = byteSize
        self.importedAt = importedAt
    }

    /// The full span of the recording on the original timeline.
    public var timeRange: TimeRange { TimeRange(start: .zero, end: duration) }
}
