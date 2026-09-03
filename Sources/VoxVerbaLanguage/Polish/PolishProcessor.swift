import Foundation
import VoxVerbaCore

/// Whether a polished window was accepted, and how.
public enum PolishDisposition: String, Sendable, Codable {
    case accepted
    case acceptedAfterRetry
    /// Failed validation twice. The CLEAN text stands and the segment is flagged.
    case fellBackToClean
}

/// One sentence's polish result, with the provenance needed to show a diff.
public struct PolishedSentence: Sendable, Codable {
    public let sourceSegmentIDs: [SegmentID]
    public let original: String
    public let revised: String
    public let report: ValidationReport
    public let disposition: PolishDisposition

    public init(
        sourceSegmentIDs: [SegmentID],
        original: String,
        revised: String,
        report: ValidationReport,
        disposition: PolishDisposition
    ) {
        self.sourceSegmentIDs = sourceSegmentIDs
        self.original = original
        self.revised = revised
        self.report = report
        self.disposition = disposition
    }
}

public struct PolishParameters: Hashable, Sendable, Codable {
    /// Sentences transformed per model call. Small by design — small windows are
    /// what make output alignable and verifiable.
    public var windowSize: Int
    /// Sentences of read-only context on each side of the window.
    public var contextSentences: Int
    public var thresholds: ValidationThresholds
    /// Version of the frozen system prompt, recorded in provenance.
    public var promptVersion: String

    public init(
        windowSize: Int = 5,
        contextSentences: Int = 1,
        thresholds: ValidationThresholds = .default,
        promptVersion: String = "polish-v1"
    ) {
        self.windowSize = Swift.max(1, windowSize)
        self.contextSentences = Swift.max(0, contextSentences)
        self.thresholds = thresholds
        self.promptVersion = promptVersion
    }

    public static let `default` = PolishParameters()
}

/// Produces the POLISHED variant (§13).
///
/// A readability transformation, not a summary. The model never sees enough of the
/// transcript at once to summarize it, and every window it returns must survive
/// the validation gauntlet before it is accepted.
///
/// - Note: Phase 6 implements this, after Phase 5 has proven the gauntlet.
public protocol PolishProcessing: Sendable {
    func process(
        clean: Transcript,
        parameters: PolishParameters,
        host: any LanguageModelHosting,
        progress: @Sendable (Double) -> Void
    ) async throws -> (transcript: Transcript, sentences: [PolishedSentence])
}

/// Phase 6 implementation site.
public struct PolishProcessor: PolishProcessing {
    public let validator: any Validating

    public init(validator: any Validating = ValidationGauntlet()) {
        self.validator = validator
    }

    public func process(
        clean: Transcript,
        parameters: PolishParameters,
        host: any LanguageModelHosting,
        progress: @Sendable (Double) -> Void
    ) async throws -> (transcript: Transcript, sentences: [PolishedSentence]) {
        throw VoxVerbaError.notImplemented("PolishProcessor.process — Phase 6")
    }
}
