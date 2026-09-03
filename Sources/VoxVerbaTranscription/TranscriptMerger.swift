import Foundation
import VoxVerbaCore

/// Reassembles chunk transcripts into one continuous transcript (§15).
///
/// Chunking is an internal implementation detail; the user never sees it. The
/// merger orders results by ``ChunkSpec/sequence``, joins soft boundaries plainly,
/// and de-duplicates hard-cut overlaps by aligning word timestamps across the
/// overlapping span. Where alignment fails it splits at the nominal boundary and
/// records ``SegmentWarning/mergeAmbiguity`` rather than hiding the uncertainty.
///
/// Paragraph and section breaks come from the measured gaps in the `SilenceMap`,
/// which is how §7's pause semantics survive silence being skipped.
///
/// - Note: Phase 2 implements this.
public protocol TranscriptMerging: Sendable {
    func merge(
        chunks: [ChunkTranscript],
        plan: ChunkPlan,
        silenceMap: SilenceMap,
        provenance: Provenance
    ) throws -> Transcript
}

/// Phase 2 implementation site.
public struct TranscriptMerger: TranscriptMerging {
    /// Words compared on each side of a hard cut when searching for the splice point.
    public let overlapSearchWords: Int

    public init(overlapSearchWords: Int = 40) {
        self.overlapSearchWords = overlapSearchWords
    }

    public func merge(
        chunks: [ChunkTranscript],
        plan: ChunkPlan,
        silenceMap: SilenceMap,
        provenance: Provenance
    ) throws -> Transcript {
        throw VoxVerbaError.notImplemented("TranscriptMerger.merge — Phase 2")
    }
}
