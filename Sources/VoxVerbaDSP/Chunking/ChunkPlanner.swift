import Foundation
import VoxVerbaCore

/// Chooses transcription work-unit boundaries (§8).
///
/// The planner does not cut every N seconds. For each boundary it searches
/// `[minDuration, maxDuration]` for the best silence gap, scoring candidates on
/// gap length, proximity to the target duration, and how far the gap sits below
/// the noise floor. The cut goes at the gap's midpoint.
///
/// When no gap in the window clears the minimum score — continuous speech, a
/// lecture without pauses, music underneath — the planner forces a cut at
/// `maxDuration`, marks it ``BoundaryKind/hardCut``, and extends the next chunk
/// backward by `overlapDuration` so the merger can de-duplicate.
///
/// - Note: Phase 1 implements the search. Its invariants — total coverage, no
///   gaps, monotonic sequence, overlap only on hard cuts — are asserted by
///   property-based tests over randomly generated silence maps.
public protocol ChunkPlanning: Sendable {
    func plan(
        silenceMap: SilenceMap,
        parameters: ChunkParameters,
        parameterHash: String
    ) throws -> ChunkPlan
}

/// Weights for the boundary scoring function. Exposed for tuning and testing.
public struct BoundaryScoreWeights: Hashable, Sendable {
    /// Weight on gap duration, saturating at `gapSaturation`.
    public var gapDuration: Double
    /// Weight on proximity to the target chunk duration.
    public var targetProximity: Double
    /// Weight on how far the gap sits below the local noise floor.
    public var silenceDepth: Double
    /// Gap length beyond which extra duration stops improving the score.
    public var gapSaturation: MediaTime

    public init(
        gapDuration: Double = 0.5,
        targetProximity: Double = 0.3,
        silenceDepth: Double = 0.2,
        gapSaturation: MediaTime = .seconds(2)
    ) {
        self.gapDuration = gapDuration
        self.targetProximity = targetProximity
        self.silenceDepth = silenceDepth
        self.gapSaturation = gapSaturation
    }

    public static let `default` = BoundaryScoreWeights()
}

/// Phase 1 implementation site.
public struct ChunkPlanner: ChunkPlanning {
    public let weights: BoundaryScoreWeights

    public init(weights: BoundaryScoreWeights = .default) {
        self.weights = weights
    }

    public func plan(
        silenceMap: SilenceMap,
        parameters: ChunkParameters,
        parameterHash: String
    ) throws -> ChunkPlan {
        throw VoxVerbaError.notImplemented("ChunkPlanner.plan — Phase 1")
    }
}
