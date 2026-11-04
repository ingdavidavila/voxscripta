import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaCoreCxx
import VoxScriptaCxxShim
import VoxScriptaDSP

/// Holds the C++ chunk planner and the Swift original to the same plan.
///
/// Chunking decides where the recogniser is asked to start and stop, so a
/// boundary that moves by one frame moves a word across a chunk edge, and a
/// word on an edge is the one most likely to come back wrong. A plan is also
/// the unit of resume: the manifest records it, and a port that planned
/// differently would make a project started on one platform unresumable on
/// another.
///
/// The input is a real `SilenceMap` from the detector rather than a
/// hand-built one, so this runs on exactly what the previous stage produces —
/// and the detector is itself held to parity next door.
@Suite("Chunk plan parity")
struct ChunkPlanParityTests {

    private typealias Signal = SilenceParityTests.Signal

    /// Patterns long enough to be chunked. The planner's thresholds are in
    /// minutes, so a signal has to be minutes long before it has any decision
    /// to make — at 10 ms a frame, six thousand frames is a minute.
    private static let longSignals: [(name: String, signal: Signal)] = [
        ("eight minutes, regular pauses",
         Signal(pattern: Array(repeating: (loud: 1_800, quiet: 120), count: 25), seed: 11)),
        ("twelve minutes, uneven pauses",
         Signal(pattern: (1...30).map { (loud: 1_200 + $0 * 60, quiet: 60 + ($0 % 7) * 40) },
                seed: 12)),
        ("unbroken speech, no gap to cut on",
         // Forces hard cuts: nothing above min_boundary_gap anywhere.
         Signal(pattern: [(loud: 40_000, quiet: 0)], seed: 13)),
        ("one long pause in the middle",
         Signal(pattern: [(loud: 18_000, quiet: 900), (loud: 18_000, quiet: 0)], seed: 14)),
    ]

    private static let parameterSets: [(name: String, swift: ChunkParameters)] = [
        ("default", ChunkParameters()),
        ("short chunks", {
            var p = ChunkParameters()
            p.minDuration = .seconds(30)
            p.targetDuration = .seconds(60)
            p.maxDuration = .seconds(90)
            return p
        }()),
        ("no overlap", {
            var p = ChunkParameters()
            p.overlapDuration = .zero
            return p
        }()),
    ]

    static var names: [String] { longSignals.map(\.name) }

    private func signal(_ name: String) -> Signal {
        Self.longSignals.first { $0.name == name }!.signal
    }

    private func cxxChunkParameters(_ p: ChunkParameters) -> voxscripta.ChunkParameters {
        var c = voxscripta.ChunkParameters()
        c.min_duration = voxscripta.MediaTime(p.minDuration.nanoseconds)
        c.max_duration = voxscripta.MediaTime(p.maxDuration.nanoseconds)
        c.target_duration = voxscripta.MediaTime(p.targetDuration.nanoseconds)
        c.overlap_duration = voxscripta.MediaTime(p.overlapDuration.nanoseconds)
        c.min_boundary_gap = voxscripta.MediaTime(p.minBoundaryGap.nanoseconds)
        return c
    }

    // ── The comparison ──────────────────────────────────────────────────────

    @Test("Chunk boundaries agree exactly", arguments: names, parameterSets)
    func plansAgree(
        named: String,
        parameters: (name: String, swift: ChunkParameters)
    ) throws {
        let label = "\(named) / \(parameters.name)"
        let s = signal(named)
        let duration = FrameGeometry.default.time(ofFrame: s.count)

        // Both planners are fed each side's own silence map, not one side's
        // map twice. If the detectors disagreed, this would report it as a
        // chunk disagreement — which is why the detector has its own suite
        // and this one is read second.
        let swiftFeatures = FrameFeatures(
            rmsDB: s.rms, zeroCrossingRate: s.zcr,
            spectralFlatness: s.flatness, geometry: .default)
        let swiftMap = try SilenceDetector().detect(
            features: swiftFeatures, parameters: SilenceParameters(),
            sourceDuration: duration, parameterHash: "parity")

        let cxxFeatures = s.rms.withUnsafeBufferPointer { r in
            s.zcr.withUnsafeBufferPointer { z in
                s.flatness.withUnsafeBufferPointer { f in
                    voxscripta.shim.features(r.baseAddress, z.baseAddress, f.baseAddress,
                                             Int32(s.count), voxscripta.FrameGeometry())
                }
            }
        }
        let cxxMap = voxscripta.SilenceDetector().detect(
            cxxFeatures, voxscripta.SilenceParameters(),
            voxscripta.MediaTime(duration.nanoseconds), std.string("parity"))

        let cxxParams = cxxChunkParameters(parameters.swift)
        let status = voxscripta.shim.plan_status(voxscripta.ChunkPlanner(), cxxMap, cxxParams)

        let swiftPlan = try ChunkPlanner().plan(
            silenceMap: swiftMap, parameters: parameters.swift, parameterHash: "parity")
        #expect(status == 0, "\(label): Swift planned, C++ returned status \(status)")
        guard status == 0 else { return }

        let cxxPlan = voxscripta.ChunkPlanner().plan(cxxMap, cxxParams, std.string("parity"))
        let theirCount = Int(voxscripta.shim.chunk_count(cxxPlan))
        #expect(swiftPlan.chunks.count == theirCount, "\(label): chunk count")

        // Not vacuous. Two empty plans agree perfectly and prove nothing, so
        // the fixtures are asserted to actually reach the planner's
        // thresholds and produce more than a single chunk.
        #expect(swiftPlan.chunks.count > 1,
                "\(label): fixture produced \(swiftPlan.chunks.count) chunk(s) — too short to test chunking")

        for i in 0..<Swift.min(swiftPlan.chunks.count, theirCount) {
            let mine = swiftPlan.chunks[i]
            #expect(mine.sequence == Int(voxscripta.shim.chunk_sequence(cxxPlan, Int32(i))),
                    "\(label): chunk \(i) sequence")

            let original = voxscripta.shim.chunk_original(cxxPlan, Int32(i))
            #expect(mine.originalRange.start.nanoseconds == original.start_time().nanoseconds(),
                    "\(label): chunk \(i) original start")
            #expect(mine.originalRange.end.nanoseconds == original.end_time().nanoseconds(),
                    "\(label): chunk \(i) original end")

            let processed = voxscripta.shim.chunk_processed(cxxPlan, Int32(i))
            #expect(mine.processedRange.start.nanoseconds == processed.start_time().nanoseconds(),
                    "\(label): chunk \(i) processed start")
            #expect(mine.processedRange.end.nanoseconds == processed.end_time().nanoseconds(),
                    "\(label): chunk \(i) processed end")

            #expect(mine.sampleRange.start
                    == voxscripta.shim.chunk_sample_start(cxxPlan, Int32(i)),
                    "\(label): chunk \(i) sample start")
            #expect(mine.sampleRange.count
                    == voxscripta.shim.chunk_sample_count(cxxPlan, Int32(i)),
                    "\(label): chunk \(i) sample count")

            #expect(mine.overlapLead.nanoseconds
                    == voxscripta.shim.chunk_overlap_lead_ns(cxxPlan, Int32(i)),
                    "\(label): chunk \(i) overlap lead")

            // Boundary kind decides whether the next chunk overlaps, so a
            // disagreement here changes the audio handed to the recogniser.
            let theirKind = Int(voxscripta.shim.chunk_boundary(cxxPlan, Int32(i)))
            let mineKind: Int = switch mine.boundaryKind {
            case .silence: 0
            case .hardCut: 1
            case .endOfMedia: 2
            }
            #expect(mineKind == theirKind, "\(label): chunk \(i) boundary kind")
        }

        #expect(swiftPlan.chunks.filter { $0.boundaryKind == .hardCut }.count
                == Int(voxscripta.shim.hard_cuts(cxxPlan)),
                "\(label): hard cut count")
    }
}
