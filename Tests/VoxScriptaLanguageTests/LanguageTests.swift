import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

@Suite("Validation gauntlet contract")
struct ValidationContractTests {

    @Test("All eight checks exist")
    func checkCoverage() {
        // §14's gauntlet, plus one. Adding or removing a check is a deliberate
        // act that has to update this test, which is the point — and it caught
        // orthography being added, which is how it should feel.
        //
        // Orthography is not in §14. It was added after running real Spanish
        // audio, where the model returned "Buenos dias" for "Buenos días" and
        // every other check passed it: same lemma, same content words,
        // negligible distance, simply misspelled.
        #expect(ValidationCheck.allCases.count == 8)
        let expected: Set<ValidationCheck> = [
            .cardinality, .numericConservation, .namedEntityConservation,
            .polarity, .modality, .semanticSimilarity, .extentBounds,
            .orthography,
        ]
        #expect(Set(ValidationCheck.allCases) == expected)
    }

    @Test("A report passes only when every check passes")
    func reportAggregation() {
        let allGood = ValidationReport(results: ValidationCheck.allCases.map {
            CheckResult(check: $0, passed: true)
        })
        #expect(allGood.passed)
        #expect(allGood.failures.isEmpty)

        var mixed = ValidationCheck.allCases.map { CheckResult(check: $0, passed: true) }
        mixed[1] = CheckResult(check: .numericConservation, passed: false,
                               detail: "500 became approximately 1,000")
        let report = ValidationReport(results: mixed)
        #expect(!report.passed)
        #expect(report.failures.count == 1)
        #expect(report.failureReasons == ["500 became approximately 1,000"])
    }

    @Test("Thresholds bound length in both directions")
    func thresholds() {
        let t = ValidationThresholds.default
        // An upper bound catches padding; a lower bound catches summarization.
        #expect(t.minimumLengthRatio < 1)
        #expect(t.maximumLengthRatio > 1)
        // A distance, not a similarity: lower means closer.
        #expect(t.maximumSemanticDistance > 0)
    }
}

@Suite("Polish configuration")
struct PolishConfigTests {

    @Test("Polish runs at temperature zero by default")
    func deterministic() {
        #expect(LanguageModelConfiguration.default.temperature == 0)
    }

    @Test("The system backend is the default and needs no model identifier")
    func systemDefault() {
        let c = LanguageModelConfiguration.default
        #expect(c.backend == .system)
        #expect(c.modelIdentifier == nil)
    }

    @Test("Windows are small enough to fit the system model's context")
    func windowFitsContext() {
        // The 4096-token context is not a constraint here: the anti-hallucination
        // design independently forces windows of a few sentences.
        let p = PolishParameters.default
        // One sentence per call: multi-sentence windows let the model merge and
        // then shift to fill the required count, which destroys alignment.
        #expect(p.windowSize == 1)
        #expect(p.contextSentences >= 1)
    }

    @Test("Window size is floored at 1")
    func windowFloor() {
        #expect(PolishParameters(windowSize: 0).windowSize == 1)
    }
}
