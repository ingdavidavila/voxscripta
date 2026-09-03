import Foundation

/// Why a chunk ends where it does.
///
/// The distinction drives merge behaviour: a boundary placed inside real silence
/// needs no overlap and no de-duplication, while a forced cut through speech
/// needs both.
public enum BoundaryKind: Hashable, Sendable, Codable {
    /// The planner found a silence gap of this duration and cut at its midpoint.
    case silence(gapDuration: MediaTime)
    /// No acceptable gap existed within bounds; the cut goes through speech.
    case hardCut
    /// The final chunk, ending at the end of the recording.
    case endOfMedia

    public var requiresOverlap: Bool {
        if case .hardCut = self { return true }
        return false
    }
}

/// Tunable parameters for the chunk planner (§29).
public struct ChunkParameters: Hashable, Sendable, Codable {
    /// A chunk is never shorter than this, except the last one.
    public var minDuration: MediaTime
    /// A chunk is never longer than this. Reaching it forces a hard cut.
    public var maxDuration: MediaTime
    /// The planner prefers boundaries near this duration.
    public var targetDuration: MediaTime
    /// Overlap prepended to the chunk following a hard cut.
    public var overlapDuration: MediaTime
    /// Minimum gap length the planner will accept as a soft boundary.
    public var minBoundaryGap: MediaTime

    public init(
        minDuration: MediaTime = .seconds(120),
        maxDuration: MediaTime = .seconds(300),
        targetDuration: MediaTime = .seconds(240),
        overlapDuration: MediaTime = .seconds(3),
        minBoundaryGap: MediaTime = .milliseconds(400)
    ) {
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.targetDuration = targetDuration
        self.overlapDuration = overlapDuration
        self.minBoundaryGap = minBoundaryGap
    }

    public static let `default` = ChunkParameters()
}

/// One unit of transcription work.
///
/// A chunk is a *view* into the canonical PCM file, not a separate audio file.
/// It exists to give the pipeline checkpoint boundaries for resume, memory
/// boundaries for a bounded footprint, and progress boundaries for the UI —
/// deliberately not to fit any model's input window.
public struct ChunkSpec: Hashable, Sendable, Codable, Identifiable {
    public let id: ChunkID
    /// Authoritative ordering. Chunks complete out of order; they merge by this.
    public let sequence: Int
    /// Span on the original recording's timeline.
    public let originalRange: TimeRange
    /// Span on the silence-skipped timeline.
    public let processedRange: TimeRange
    /// The samples to read from `canonical.f32`.
    public let sampleRange: SampleRange
    public let boundaryKind: BoundaryKind
    /// Audio prepended from the previous chunk. Non-zero only after a hard cut.
    public let overlapLead: MediaTime

    public init(
        id: ChunkID = ChunkID(),
        sequence: Int,
        originalRange: TimeRange,
        processedRange: TimeRange,
        sampleRange: SampleRange,
        boundaryKind: BoundaryKind,
        overlapLead: MediaTime = .zero
    ) {
        self.id = id
        self.sequence = sequence
        self.originalRange = originalRange
        self.processedRange = processedRange
        self.sampleRange = sampleRange
        self.boundaryKind = boundaryKind
        self.overlapLead = overlapLead
    }

    public var duration: MediaTime { originalRange.duration }
}

/// The full ordered set of work units for a recording.
public struct ChunkPlan: Sendable, Codable {
    public let chunks: [ChunkSpec]
    public let parameters: ChunkParameters
    /// Hash over the parameters and the silence map's hash. The invalidation key.
    public let parameterHash: String

    public init(chunks: [ChunkSpec], parameters: ChunkParameters, parameterHash: String) {
        self.chunks = chunks
        self.parameters = parameters
        self.parameterHash = parameterHash
    }

    public var count: Int { chunks.count }
    public var totalDuration: MediaTime {
        chunks.reduce(MediaTime.zero) { $0 + $1.duration }
    }
    public var hardCutCount: Int {
        chunks.filter { $0.boundaryKind.requiresOverlap }.count
    }
}
