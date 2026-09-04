import Testing
import Foundation
import VoxVerbaCore
@testable import VoxVerbaLanguage

@Suite("Validation gauntlet contract")
struct ValidationContractTests {

    @Test("All seven documented checks exist")
    func checkCoverage() {
        // §14's gauntlet. Adding or removing a check is a deliberate act that has
        // to update this test, which is the point.
        #expect(ValidationCheck.allCases.count == 7)
        let expected: Set<ValidationCheck> = [
            .cardinality, .numericConservation, .namedEntityConservation,
            .polarity, .modality, .semanticSimilarity, .extentBounds,
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
        #expect(t.minimumSemanticSimilarity > 0.5)
        #expect(t.minimumSemanticSimilarity < 1)
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
        #expect(p.windowSize <= 8)
        #expect(p.windowSize >= 1)
        #expect(p.contextSentences >= 1)
    }

    @Test("Window size is floored at 1")
    func windowFloor() {
        #expect(PolishParameters(windowSize: 0).windowSize == 1)
    }
}

@Suite("Language placeholders announce themselves")
struct LanguagePlaceholderTests {

    @Test("Validator")
    func validator() {
        #expect(throws: VoxVerbaError.self) {
            try ValidationGauntlet().validate(original: ["a"], revised: ["b"], thresholds: .default)
        }
    }

    @Test("Model host")
    func host() async {
        let host = LanguageModelHost()
        #expect(await host.isLoaded == false)
        await #expect(throws: VoxVerbaError.self) { try await host.load() }
        await #expect(throws: VoxVerbaError.self) {
            try await host.generate(prompt: "x", systemInstructions: "y")
        }
    }

    @Test("Polish processor")
    func polish() async {
        let t = Transcript(variant: .clean, segments: [], provenance: Provenance())
        await #expect(throws: VoxVerbaError.self) {
            _ = try await PolishProcessor().process(clean: t, parameters: .default,
                                                    host: LanguageModelHost()) { _ in }
        }
    }
}
