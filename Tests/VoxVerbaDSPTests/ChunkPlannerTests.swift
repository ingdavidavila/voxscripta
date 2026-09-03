import Testing
import Foundation
import VoxVerbaCore
import VoxVerbaTestSupport
@testable import VoxVerbaDSP

/// Builds a random but well-formed silence map, for property testing.
///
/// The planner's invariants must hold for every shape of input, not only the
/// handful the corpus happens to contain — so the inputs are generated rather
/// than enumerated, from a seeded source so a failure is reproducible.
func randomSilenceMap(seed: UInt64, regionCount: Int) -> SilenceMap {
    var rng = DeterministicRandom(seed: seed)
    var regions: [SpeechRegion] = []
    var gaps: [SilenceGap] = []
    var t = MediaTime.seconds(rng.uniform() * 3)

    if t > .zero {
        gaps.append(SilenceGap(range: TimeRange(start: .zero, end: t), meanEnergyDB: -60))
    }
    for _ in 0..<regionCount {
        let speech = MediaTime.seconds(1 + rng.uniform() * 90)
        let end = t + speech
        regions.append(SpeechRegion(range: TimeRange(start: t, end: end),
                                    meanEnergyDB: -20, peakEnergyDB: -12))
        // Gap lengths straddle minBoundaryGap so both usable and unusable
        // candidates occur.
        let gap = MediaTime.seconds(0.05 + rng.uniform() * 4)
        gaps.append(SilenceGap(range: TimeRange(start: end, end: end + gap), meanEnergyDB: -60))
        t = end + gap
    }
    return SilenceMap(speechRegions: regions, gaps: gaps, noiseFloorProfile: [],
                      parameters: .default, parameterHash: "prop", sourceDuration: t)
}

@Suite("Chunk planner")
struct ChunkPlannerTests {

    private func assertInvariants(
        _ plan: ChunkPlan,
        _ map: SilenceMap,
        _ params: ChunkParameters,
        _ label: String
    ) {
        guard let firstRegion = map.speechRegions.first,
              let lastRegion = map.speechRegions.last else { return }
        #expect(!plan.chunks.isEmpty, "\(label): produced no chunks")

        // Sequence numbers are dense and ordered — the merger relies on this.
        #expect(plan.chunks.map(\.sequence) == Array(0..<plan.chunks.count), "\(label): sequence")

        // Coverage: the plan spans exactly the speech extent, with no gap between
        // consecutive chunks.
        #expect(plan.chunks.first!.originalRange.start == firstRegion.range.start, "\(label): start")
        #expect(plan.chunks.last!.originalRange.end == lastRegion.range.end, "\(label): end")

        for (a, b) in zip(plan.chunks, plan.chunks.dropFirst()) {
            if b.overlapLead > .zero {
                // Only a hard cut may overlap, and only by its declared amount.
                #expect(a.boundaryKind.requiresOverlap, "\(label): overlap without a hard cut")
                #expect(b.originalRange.start == a.originalRange.end - b.overlapLead,
                        "\(label): overlap amount")
            } else {
                #expect(b.originalRange.start == a.originalRange.end, "\(label): contiguity")
            }
        }

        // Only hard cuts carry overlap.
        for chunk in plan.chunks where chunk.overlapLead > .zero {
            #expect(chunk.sequence > 0, "\(label): first chunk cannot have overlap")
        }

        // Duration bounds hold for every chunk but the last.
        for chunk in plan.chunks.dropLast() {
            #expect(chunk.duration <= params.maxDuration + .milliseconds(1),
                    "\(label): chunk \(chunk.sequence) exceeds maxDuration")
        }

        // Processed time is monotonic and never exceeds total speech.
        for chunk in plan.chunks {
            #expect(chunk.processedRange.start <= chunk.processedRange.end, "\(label): processed order")
            #expect(chunk.processedRange.end <= map.speechDuration + .milliseconds(1),
                    "\(label): processed overflow")
        }

        // The sample range matches the original range at the canonical rate.
        for chunk in plan.chunks {
            let expected = chunk.originalRange.start.samples(at: CanonicalFormat.sampleRate)
            #expect(chunk.sampleRange.start == expected, "\(label): sample start")
        }
    }

    @Test("Invariants hold across many random silence maps")
    func propertyInvariants() throws {
        let params = ChunkParameters.default
        for seed in UInt64(1)...60 {
            let count = Int(seed % 40) + 1
            let map = randomSilenceMap(seed: seed, regionCount: count)
            let plan = try ChunkPlanner().plan(silenceMap: map, parameters: params, parameterHash: "p")
            assertInvariants(plan, map, params, "seed \(seed)")
        }
    }

    @Test("Invariants hold across varied chunk parameters")
    func variedParameters() throws {
        let map = randomSilenceMap(seed: 99, regionCount: 30)
        let variants = [
            ChunkParameters(minDuration: .seconds(30), maxDuration: .seconds(60),
                            targetDuration: .seconds(45), overlapDuration: .seconds(2)),
            ChunkParameters(minDuration: .seconds(5), maxDuration: .seconds(600),
                            targetDuration: .seconds(300), overlapDuration: .seconds(1)),
            ChunkParameters(minDuration: .seconds(120), maxDuration: .seconds(120),
                            targetDuration: .seconds(120), overlapDuration: .seconds(5)),
        ]
        for (i, params) in variants.enumerated() {
            let plan = try ChunkPlanner().plan(silenceMap: map, parameters: params, parameterHash: "p")
            assertInvariants(plan, map, params, "variant \(i)")
        }
    }

    @Test("Boundaries prefer silence when silence is available")
    func prefersSilenceBoundaries() async throws {
        // A recording with regular pauses should need no hard cuts at all.
        let map = randomSilenceMap(seed: 7, regionCount: 25)
        let plan = try ChunkPlanner().plan(silenceMap: map, parameters: .default, parameterHash: "p")
        #expect(plan.hardCutCount == 0)
        for chunk in plan.chunks.dropLast() {
            if case .silence = chunk.boundaryKind {} else {
                Issue.record("chunk \(chunk.sequence) did not cut at silence")
            }
        }
    }

    @Test("Continuous speech forces hard cuts with overlap")
    func continuousSpeechHardCuts() async throws {
        // Six minutes with no usable pause, against a 300 s maximum: the planner
        // has no choice but to cut through speech.
        let run = try await DetectionRun(StandardCorpus.continuousSpeech)
        let params = ChunkParameters(minDuration: .seconds(60), maxDuration: .seconds(120),
                                     targetDuration: .seconds(90), overlapDuration: .seconds(3))
        let plan = try ChunkPlanner().plan(silenceMap: run.map, parameters: params, parameterHash: "p")

        #expect(plan.chunks.count >= 3)
        #expect(plan.hardCutCount >= 2)
        for chunk in plan.chunks.dropFirst() {
            #expect(chunk.overlapLead == .seconds(3))
        }
        assertInvariants(plan, run.map, params, "continuous")
    }

    @Test("A recording shorter than one chunk yields exactly one chunk")
    func singleChunk() async throws {
        let run = try await DetectionRun(StandardCorpus.basic)   // 18 s
        let plan = try ChunkPlanner().plan(silenceMap: run.map, parameters: .default, parameterHash: "p")
        #expect(plan.chunks.count == 1)
        #expect(plan.chunks[0].boundaryKind == .endOfMedia)
        #expect(plan.chunks[0].overlapLead == .zero)
    }

    @Test("Planning is deterministic")
    func deterministic() throws {
        let map = randomSilenceMap(seed: 42, regionCount: 20)
        let a = try ChunkPlanner().plan(silenceMap: map, parameters: .default, parameterHash: "p")
        let b = try ChunkPlanner().plan(silenceMap: map, parameters: .default, parameterHash: "p")
        #expect(a.chunks.map(\.originalRange) == b.chunks.map(\.originalRange))
        #expect(a.chunks.map(\.boundaryKind) == b.chunks.map(\.boundaryKind))
    }

    @Test("A map with no speech is rejected rather than planned")
    func noSpeech() {
        let empty = SilenceMap(speechRegions: [], gaps: [], noiseFloorProfile: [],
                               parameters: .default, parameterHash: "x", sourceDuration: .seconds(10))
        #expect(throws: VoxVerbaError.noSpeechDetected) {
            try ChunkPlanner().plan(silenceMap: empty, parameters: .default, parameterHash: "p")
        }
    }

    @Test("Scoring prefers longer gaps and boundaries nearer the target")
    func scoring() {
        let planner = ChunkPlanner()
        let params = ChunkParameters.default
        let start = MediaTime.zero
        let target = params.targetDuration

        func score(gap seconds: Double, at time: MediaTime) -> Double {
            planner.boundaryScore(
                gap: SilenceGap(range: TimeRange(start: time, duration: .seconds(seconds)),
                                meanEnergyDB: -60),
                midpoint: time, chunkStart: start, parameters: params, speechReference: -20)
        }
        // A longer gap at the same position scores higher.
        #expect(score(gap: 2.0, at: target) > score(gap: 0.5, at: target))
        // The same gap nearer the target scores higher.
        #expect(score(gap: 1.0, at: target) > score(gap: 1.0, at: params.maxDuration))
    }
}
