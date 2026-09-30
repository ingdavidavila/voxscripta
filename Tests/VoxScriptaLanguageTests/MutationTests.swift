import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport
@testable import VoxScriptaLanguage

/// The Phase 5 gate.
///
/// Waiting for a language model to produce bad output is neither reliable nor
/// reproducible, so known-good output is corrupted deliberately, one damage class
/// at a time. **A corruption that survives the gauntlet is a test failure.** That
/// turns "does it hallucinate?" from a worry into a deterministic assertion, and
/// makes the validator's coverage explicit rather than hoped for.
@Suite("Mutation testing")
struct MutationTests {

    private let gauntlet = ValidationGauntlet()

    @Test("Every corruption in the corpus is rejected")
    func allMutationsCaught() throws {
        var survivors: [String] = []

        for mutation in MutationCorpus.mutations {
            let report = try gauntlet.validate(
                original: mutation.original, revised: mutation.corrupted,
                thresholds: .default)
            if report.passed {
                survivors.append("\(mutation.category)/\(mutation.name)")
            }
        }

        #expect(survivors.isEmpty,
                "corruptions passed validation: \(survivors.joined(separator: ", "))")
    }

    @Test("Each corruption is caught by the check meant to catch it")
    func caughtByExpectedCheck() throws {
        var misattributed: [String] = []

        for mutation in MutationCorpus.mutations {
            let report = try gauntlet.validate(
                original: mutation.original, revised: mutation.corrupted,
                thresholds: .default)
            let failedChecks = Set(report.failures.map(\.check.rawValue))
            if !failedChecks.contains(mutation.expectedCheck) {
                misattributed.append(
                    "\(mutation.name): expected \(mutation.expectedCheck), "
                    + "got \(failedChecks.sorted().joined(separator: "+"))")
            }
        }

        // A miss here is a real signal even when the corruption was caught by
        // some other check: it means the check that should own this damage class
        // is blind to it, and a variant that dodges the accidental catcher would
        // slip through.
        #expect(misattributed.isEmpty, "\(misattributed.joined(separator: " | "))")
    }

    @Test("Legitimate polish is not rejected")
    func noFalsePositives() throws {
        var rejected: [String] = []

        for pair in MutationCorpus.validPairs {
            let report = try gauntlet.validate(
                original: pair.original, revised: pair.revised, thresholds: .default)
            if !report.passed {
                rejected.append("\(pair.name): \(report.failureReasons.joined(separator: "; "))")
            }
        }

        // A validator that rejects good output is as useless as one that admits
        // bad output: every window would fall back to CLEAN and POLISHED would
        // do nothing at all.
        #expect(rejected.isEmpty, "\(rejected.joined(separator: " | "))")
    }

    @Test("Every damage class in the corpus is exercised")
    func categoryCoverage() {
        let expected: Set<String> = [
            "numeric", "entity", "polarity", "modality", "cardinality", "extent", "semantic",
        ]
        #expect(MutationCorpus.categories == expected)
        // Each category needs more than one instance, or a single lucky catch
        // reads as coverage.
        for category in expected {
            let count = MutationCorpus.mutations.count { $0.category == category }
            #expect(count >= 2, "category '\(category)' has only \(count) mutation(s)")
        }
    }

    @Test("Identical input and output always passes")
    func identityPasses() throws {
        for pair in MutationCorpus.validPairs {
            let report = try gauntlet.validate(
                original: pair.original, revised: pair.original, thresholds: .default)
            #expect(report.passed, "'\(pair.name)' failed against itself: \(report.failureReasons)")
        }
    }

    @Test("The embedding check alone would miss most dangerous corruptions")
    func semanticCheckIsNotSufficient() throws {
        // Measured, and the strongest argument against collapsing the gauntlet
        // into "just compare embeddings". Changing a number, renaming a person
        // and dropping a hedge all sit far below the drift threshold: they are
        // small, fluent, local edits that barely move a sentence vector, and they
        // are exactly the transformations §14 cares most about.
        let sim = SemanticSimilarity()
        guard sim.isAvailable else { return }
        let limit = ValidationThresholds.default.maximumSemanticDistance

        let sneaky = ["number changed", "person renamed", "hedge dropped"]
        for name in sneaky {
            guard let mutation = MutationCorpus.mutations.first(where: { $0.name == name })
            else { Issue.record("missing mutation '\(name)'"); continue }

            let drift = zip(mutation.original, mutation.corrupted)
                .compactMap { sim.distance($0, $1) }.max() ?? 0
            #expect(drift < limit,
                    "'\(name)' drifted \(drift), so this test no longer demonstrates its point")

            // The gauntlet as a whole still rejects it, via the specific checks.
            let report = try gauntlet.validate(
                original: mutation.original, revised: mutation.corrupted, thresholds: .default)
            #expect(!report.passed)
            #expect(!report.failures.contains { $0.check == .semanticSimilarity },
                    "'\(name)' was caught by the embedding check after all")
        }
    }

    @Test("A report names what went wrong")
    func reportsAreActionable() throws {
        let mutation = MutationCorpus.mutations.first { $0.name == "number changed" }!
        let report = try gauntlet.validate(
            original: mutation.original, revised: mutation.corrupted, thresholds: .default)

        #expect(!report.passed)
        // The UI shows these to a person deciding whether to keep a sentence, so
        // "validation failed" is not good enough.
        let reasons = report.failureReasons.joined(separator: " ")
        #expect(reasons.contains("500") || reasons.contains("1000"),
                "the report did not name the offending number: \(reasons)")
    }
}

@Suite("Individual checks")
struct IndividualCheckTests {

    private let gauntlet = ValidationGauntlet()

    private func run(_ original: [String], _ revised: [String]) throws -> ValidationReport {
        try gauntlet.validate(original: original, revised: revised, thresholds: .default)
    }

    @Test("Numbers are compared by value, not by notation")
    func numericNotation() throws {
        // "five hundred" and "500" are the same quantity written two ways, and a
        // polish pass may legitimately switch between them.
        let report = try run(["We sold five hundred units."], ["We sold 500 units."])
        #expect(report.results.first { $0.check == .numericConservation }?.passed == true)

        // But 500 and 1,000 are different quantities, however plausible.
        let bad = try run(["We sold five hundred units."], ["We sold 1,000 units."])
        #expect(bad.results.first { $0.check == .numericConservation }?.passed == false)
    }

    @Test("Cardinality is checked before anything that pairs sentences")
    func cardinalityShortCircuits() throws {
        let report = try run(["One.", "Two."], ["One and two."])
        #expect(!report.passed)
        // Later checks compare by index, so running them on mismatched counts
        // would produce meaningless failures rather than one clear one.
        #expect(report.results.count == 1)
        #expect(report.results[0].check == .cardinality)
    }

    @Test("Polarity is per sentence, so a moved negation is still caught")
    func polarityPerSentence() throws {
        // The window has one negation before and one after, so a window-level
        // count would see no change at all.
        let report = try run(["We did not approve it.", "The committee met."],
                             ["We approved it.", "The committee did not meet."])
        #expect(report.results.first { $0.check == .polarity }?.passed == false)
    }

    @Test("Contractions count as negations")
    func contractionsCount() throws {
        let report = try run(["We didn't approve it."], ["We did approve it."])
        #expect(report.results.first { $0.check == .polarity }?.passed == false)
    }

    @Test("Entity comparison survives an unreliable tagger")
    func entityComparison() throws {
        // The on-device tagger mislabels "David" as a place name. Comparing
        // strings rather than types means a consistent mislabel is harmless,
        // while an actual rename is still caught.
        let ok = try run(["David met Sarah Chen."], ["David met with Sarah Chen."])
        #expect(ok.results.first { $0.check == .namedEntityConservation }?.passed == true)

        let bad = try run(["David met Sarah Chen."], ["David met Rebecca Chen."])
        #expect(bad.results.first { $0.check == .namedEntityConservation }?.passed == false)
    }

    @Test("Summarization is caught by extent, not by meaning")
    func summarizationCaught() throws {
        let long = "The committee reviewed the quarterly figures in detail and concluded "
            + "that the reporting process needed substantial revision before the next cycle."
        let report = try run([long], ["The committee wanted changes."])
        #expect(report.results.first { $0.check == .extentBounds }?.passed == false)
    }

    @Test("An empty revision is rejected rather than divided by zero")
    func emptyRevision() throws {
        let report = try run(["Something was said."], [""])
        #expect(!report.passed)
    }

    @Test("The check without an embedding model abstains visibly")
    func abstainsWithoutModel() throws {
        // A missing model must not make the check pass vacuously and silently.
        let report = try run(["We shipped it."], ["We shipped it."])
        let semantic = report.results.first { $0.check == .semanticSimilarity }
        #expect(semantic != nil)
        if semantic?.detail?.contains("skipped") == true {
            #expect(semantic?.passed == true)
        }
    }
}
