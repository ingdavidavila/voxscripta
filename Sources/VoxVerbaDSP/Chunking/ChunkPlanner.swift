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

/// Greedy boundary search with a hard-cut fallback.
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
        let regions = silenceMap.speechRegions
        guard let first = regions.first, let last = regions.last else {
            throw VoxVerbaError.noSpeechDetected
        }
        guard parameters.minDuration <= parameters.maxDuration else {
            throw VoxVerbaError.analysisFailed(
                stage: "chunk planning",
                reason: "minimum chunk duration exceeds the maximum"
            )
        }

        // Chunks tile the span from the first speech instant to the last. Leading
        // and trailing silence is dropped entirely — it is never work.
        let mediaStart = first.range.start
        let mediaEnd = last.range.end

        // Reference speech level, for scoring how deep a candidate gap sits.
        let speechReference = regions.reduce(Float(0)) { $0 + $1.meanEnergyDB } / Float(regions.count)

        var chunks: [ChunkSpec] = []
        var cursor = mediaStart
        var pendingOverlap = MediaTime.zero
        var sequence = 0

        while cursor < mediaEnd {
            let hardLimit = cursor + parameters.maxDuration
            let earliest = cursor + parameters.minDuration

            // The remainder fits in one chunk: take it and stop.
            if hardLimit >= mediaEnd {
                chunks.append(makeChunk(
                    sequence: sequence, start: cursor, end: mediaEnd,
                    boundary: .endOfMedia, overlapLead: pendingOverlap, map: silenceMap))
                break
            }

            // Candidate boundaries: gap midpoints inside the search window.
            var best: (time: MediaTime, gap: MediaTime, score: Double)?
            for gap in silenceMap.gaps {
                guard gap.duration >= parameters.minBoundaryGap else { continue }
                let midpoint = gap.range.start + gap.duration * 0.5
                guard midpoint > earliest, midpoint <= hardLimit else { continue }

                let score = boundaryScore(
                    gap: gap, midpoint: midpoint, chunkStart: cursor,
                    parameters: parameters, speechReference: speechReference)
                if best == nil || score > best!.score {
                    best = (midpoint, gap.duration, score)
                }
            }

            if let choice = best {
                chunks.append(makeChunk(
                    sequence: sequence, start: cursor, end: choice.time,
                    boundary: .silence(gapDuration: choice.gap),
                    overlapLead: pendingOverlap, map: silenceMap))
                cursor = choice.time
                pendingOverlap = .zero
            } else {
                // Continuous speech across the whole window. Cut through it and
                // give the next chunk an overlap so the merger can re-join the
                // sentence that was split.
                chunks.append(makeChunk(
                    sequence: sequence, start: cursor, end: hardLimit,
                    boundary: .hardCut, overlapLead: pendingOverlap, map: silenceMap))
                let overlap = MediaTime.min(parameters.overlapDuration, parameters.maxDuration * 0.5)
                cursor = hardLimit - overlap
                pendingOverlap = overlap
            }
            sequence += 1
        }

        return ChunkPlan(chunks: chunks, parameters: parameters, parameterHash: parameterHash)
    }

    // MARK: - Scoring

    /// Higher is a better place to cut.
    ///
    /// Three terms, in the order they matter: a longer gap is more certainly a
    /// real pause; a boundary near the target duration keeps chunks even; and a
    /// gap far below the speech level is more certainly silence rather than a
    /// quiet passage.
    func boundaryScore(
        gap: SilenceGap,
        midpoint: MediaTime,
        chunkStart: MediaTime,
        parameters: ChunkParameters,
        speechReference: Float
    ) -> Double {
        let saturation = weights.gapSaturation.seconds
        let gapTerm = Swift.min(gap.duration.seconds, saturation) / saturation

        let target = chunkStart + parameters.targetDuration
        let span = Swift.max((parameters.maxDuration - parameters.minDuration).seconds, 0.001)
        let deviation = abs((midpoint - target).seconds) / span
        let proximityTerm = Swift.max(0, 1 - deviation)

        let depth = Double(speechReference - gap.meanEnergyDB)
        let depthTerm = Swift.min(Swift.max(depth / 40, 0), 1)

        return weights.gapDuration * gapTerm
            + weights.targetProximity * proximityTerm
            + weights.silenceDepth * depthTerm
    }

    // MARK: - Construction

    private func makeChunk(
        sequence: Int,
        start: MediaTime,
        end: MediaTime,
        boundary: BoundaryKind,
        overlapLead: MediaTime,
        map: SilenceMap
    ) -> ChunkSpec {
        let original = TimeRange(start: start, end: end)
        let rate = CanonicalFormat.sampleRate
        let startSample = start.samples(at: rate)
        let endSample = end.samples(at: rate)

        // Processed time is the speech accumulated before this chunk, so a chunk
        // boundary that lands inside a gap still maps cleanly — which
        // `SilenceMap.processedTime(forOriginal:)` cannot do by design.
        let processedStart = speechDuration(in: map, upTo: start)
        let processedEnd = speechDuration(in: map, upTo: end)

        return ChunkSpec(
            sequence: sequence,
            originalRange: original,
            processedRange: TimeRange(start: processedStart, end: processedEnd),
            sampleRange: SampleRange(start: startSample, count: endSample - startSample),
            boundaryKind: boundary,
            overlapLead: overlapLead
        )
    }

    /// Total speech time before `time` on the original timeline.
    private func speechDuration(in map: SilenceMap, upTo time: MediaTime) -> MediaTime {
        var total = MediaTime.zero
        for region in map.speechRegions {
            if region.range.start >= time { break }
            let clipped = TimeRange(start: region.range.start,
                                    end: MediaTime.min(region.range.end, time))
            total = total + clipped.duration
        }
        return total
    }
}
