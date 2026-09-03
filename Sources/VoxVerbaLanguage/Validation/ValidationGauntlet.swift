import Foundation
import VoxVerbaCore

/// The checks a polished sentence must survive (§14).
///
/// Every check is deterministic. None of them asks a model whether the model's own
/// output was acceptable, which would be circular.
public enum ValidationCheck: String, Sendable, Codable, CaseIterable {
    /// One output sentence per input sentence. Enforced by the generation schema
    /// before any other check runs.
    case cardinality
    /// Numbers, normalized across numerals, number-words, units and magnitudes,
    /// must form the same set in and out. Strict equality, not similarity —
    /// "approximately 1,000" is *plausible*, which is exactly why a fuzzy check
    /// would let it through.
    case numericConservation
    /// People, places and organizations must form the same set in and out.
    case namedEntityConservation
    /// Negation-marker count per sentence must not change.
    case polarity
    /// Hedges must not be dropped — doing so turns a qualified claim into an assertion.
    case modality
    /// Sentence-embedding cosine similarity must clear a floor.
    case semanticSimilarity
    /// Length ratio and content-word overlap must stay in bounds, which is what
    /// catches summarization.
    case extentBounds
}

/// One check's outcome.
public struct CheckResult: Hashable, Sendable, Codable {
    public let check: ValidationCheck
    public let passed: Bool
    /// Human-readable explanation, shown in the UI when a sentence is flagged.
    public let detail: String?
    /// The measured value, where the check produces one.
    public let measurement: Double?

    public init(check: ValidationCheck, passed: Bool, detail: String? = nil, measurement: Double? = nil) {
        self.check = check
        self.passed = passed
        self.detail = detail
        self.measurement = measurement
    }
}

/// The full report for one polished window.
public struct ValidationReport: Hashable, Sendable, Codable {
    public let results: [CheckResult]

    public init(results: [CheckResult]) { self.results = results }

    public var passed: Bool { results.allSatisfy(\.passed) }
    public var failures: [CheckResult] { results.filter { !$0.passed } }
    public var failureReasons: [String] {
        failures.map { $0.detail ?? $0.check.rawValue }
    }
}

/// Thresholds for the measurement-based checks.
public struct ValidationThresholds: Hashable, Sendable, Codable {
    public var minimumSemanticSimilarity: Double
    public var minimumLengthRatio: Double
    public var maximumLengthRatio: Double
    public var minimumContentWordOverlap: Double

    public init(
        minimumSemanticSimilarity: Double = 0.85,
        minimumLengthRatio: Double = 0.5,
        maximumLengthRatio: Double = 1.5,
        minimumContentWordOverlap: Double = 0.5
    ) {
        self.minimumSemanticSimilarity = minimumSemanticSimilarity
        self.minimumLengthRatio = minimumLengthRatio
        self.maximumLengthRatio = maximumLengthRatio
        self.minimumContentWordOverlap = minimumContentWordOverlap
    }

    public static let `default` = ValidationThresholds()
}

/// Runs every check over an original/revised pair.
///
/// - Note: Phase 5 implements this — deliberately *before* Phase 6 introduces the
///   language model. The fence gets built before the gate opens, and it is proven
///   by mutation testing: known-good output is corrupted one class at a time, and
///   a corruption that passes the gauntlet is a test failure.
public protocol Validating: Sendable {
    func validate(
        original: [String],
        revised: [String],
        thresholds: ValidationThresholds
    ) throws -> ValidationReport
}

/// Phase 5 implementation site.
public struct ValidationGauntlet: Validating {
    public init() {}

    public func validate(
        original: [String],
        revised: [String],
        thresholds: ValidationThresholds
    ) throws -> ValidationReport {
        throw VoxVerbaError.notImplemented("ValidationGauntlet.validate — Phase 5")
    }
}
