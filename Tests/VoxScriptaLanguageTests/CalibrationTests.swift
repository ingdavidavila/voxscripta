import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaLanguage

/// Guards the semantic threshold against drift in the on-device model.
///
/// The threshold is a measured property of an OS-supplied embedding, not a
/// constant of nature. If a system update shifts that model, this suite fails and
/// says so, rather than the gauntlet silently starting to admit corruptions or
/// reject good output.
@Suite("Semantic distance calibration")
struct SemanticDistanceCalibrationTests {

    private func worstDistance(_ a: [String], _ b: [String], _ sim: SemanticSimilarity) -> Double {
        zip(a, b).compactMap { sim.distance($0, $1) }.max() ?? 0
    }

    @Test("Legitimate polish stays well inside the threshold")
    func validPairsPass() {
        let sim = SemanticSimilarity()
        guard sim.isAvailable else { return }
        let limit = ValidationThresholds.default.maximumSemanticDistance

        for pair in MutationCorpus.validPairs {
            let d = worstDistance(pair.original, pair.revised, sim)
            #expect(d < limit, "'\(pair.name)' measured \(d), threshold \(limit)")
        }
    }

    @Test("Meaning-changing corruptions land outside it")
    func semanticMutationsFail() {
        let sim = SemanticSimilarity()
        guard sim.isAvailable else { return }
        let limit = ValidationThresholds.default.maximumSemanticDistance

        for mutation in MutationCorpus.mutations where mutation.category == "semantic" {
            let d = worstDistance(mutation.original, mutation.corrupted, sim)
            #expect(d > limit, "'\(mutation.name)' measured \(d), threshold \(limit)")
        }
    }

    @Test("The threshold keeps a real margin on both sides")
    func separationIsComfortable() {
        let sim = SemanticSimilarity()
        guard sim.isAvailable else { return }

        let validMax = MutationCorpus.validPairs
            .map { worstDistance($0.original, $0.revised, sim) }.max() ?? 0
        let corruptMin = MutationCorpus.mutations
            .filter { $0.category == "semantic" }
            .map { worstDistance($0.original, $0.corrupted, sim) }.min() ?? .infinity

        #expect(validMax < corruptMin, "the two populations overlap; no threshold can separate them")
        // Measured at 0.548 and 0.904 when this was written. A margin under 0.15
        // means the threshold is fragile and should be re-derived rather than
        // nudged.
        #expect(corruptMin - validMax > 0.15,
                "separation collapsed to \(corruptMin - validMax): recalibrate")
    }

    @Test("Case folding is what makes the separation usable")
    func caseFoldingMatters() {
        // Recorded because it is counter-intuitive and easy to undo. Capitalizing
        // a sentence moves this model almost as far as inverting its meaning, and
        // capitalization is exactly what POLISHED is supposed to fix.
        let sim = SemanticSimilarity()
        guard sim.isAvailable else { return }
        let d = sim.distance("david met with sarah chen on tuesday",
                             "David met with Sarah Chen on Tuesday.")
        #expect(d != nil)
        #expect(d! < 0.55, "case-only differences should be near-zero, measured \(d!)")
    }
}
