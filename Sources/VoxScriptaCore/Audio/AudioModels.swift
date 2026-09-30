import Foundation

/// The format VoxScripta canonicalizes every source into before analysis.
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

/// How a project refers back to its original audio.
///
/// Both forms are non-destructive; they differ only in where the bytes live.
/// Referencing avoids duplicating a multi-gigabyte recording but breaks if the
/// user moves the file; copying is self-contained but doubles the storage. The
/// choice is a setting rather than an architectural fork — everything downstream
/// resolves this to a read-only URL and does not care which it was.
public enum SourceReference: Sendable, Codable, Hashable {
    /// A security-scoped bookmark to the file where the user keeps it.
    case bookmark(Data)
    /// A copy inside the project package's `Original/` directory.
    case insidePackage(filename: String)

    public var isCopy: Bool {
        if case .insidePackage = self { return true }
        return false
    }
}

/// An imported recording.
///
/// - Important: The original file is referenced, never owned. Nothing in this
///   codebase opens it for writing — that is what makes the §5 guarantee
///   structural rather than a matter of discipline.
public struct AudioSource: Hashable, Sendable, Codable, Identifiable {
    public let id: SourceID
    /// Where the original lives. Resolved read-only, never for writing.
    public let reference: SourceReference
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
        reference: SourceReference,
        displayName: String,
        contentHash: String,
        format: AudioFormatDescription,
        duration: MediaTime,
        byteSize: Int64,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.reference = reference
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
