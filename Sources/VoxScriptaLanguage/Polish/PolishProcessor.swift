import Foundation
import VoxScriptaCore

/// Whether a polished window was accepted, and how.
public enum PolishDisposition: String, Sendable, Codable {
    case accepted
    case acceptedAfterRetry
    /// Failed validation twice. The CLEAN text stands and the segment is flagged.
    case fellBackToClean
    /// The model itself errored. The CLEAN text stands.
    case modelFailed
}

/// One sentence's polish result, with the provenance to show a diff.
public struct PolishedSentence: Sendable, Codable {
    public let segmentID: SegmentID
    public let original: String
    public let revised: String
    public let report: ValidationReport
    public let disposition: PolishDisposition

    public init(segmentID: SegmentID, original: String, revised: String,
                report: ValidationReport, disposition: PolishDisposition) {
        self.segmentID = segmentID
        self.original = original
        self.revised = revised
        self.report = report
        self.disposition = disposition
    }

    public var wasChanged: Bool { original != revised }
}

/// The outcome of a whole polish pass.
public struct PolishResult: Sendable {
    public let transcript: Transcript
    public let sentences: [PolishedSentence]

    public init(transcript: Transcript, sentences: [PolishedSentence]) {
        self.transcript = transcript
        self.sentences = sentences
    }

    public func count(_ disposition: PolishDisposition) -> Int {
        sentences.count { $0.disposition == disposition }
    }

    /// Share of sentences the validator refused on the model's first attempt.
    ///
    /// The number the Phase 6 gate is stated in terms of. A rate near zero would
    /// suggest the checks are too loose rather than that the model is perfect.
    public var rejectionRate: Double {
        guard !sentences.isEmpty else { return 0 }
        let rejected = sentences.count {
            $0.disposition != .accepted
        }
        return Double(rejected) / Double(sentences.count)
    }

    /// Share that ended up keeping the CLEAN text.
    public var fallbackRate: Double {
        guard !sentences.isEmpty else { return 0 }
        let fell = sentences.count {
            $0.disposition == .fellBackToClean || $0.disposition == .modelFailed
        }
        return Double(fell) / Double(sentences.count)
    }
}

public struct PolishParameters: Hashable, Sendable, Codable {
    /// Sentences transformed per model call. One, by measurement.
    ///
    /// Multi-sentence windows fail in a way that is worse than a wrong count.
    /// Constrained to return five sentences for five inputs, the model merged two
    /// of them and then shifted and duplicated the rest to fill the array — the
    /// length was right and the alignment was destroyed. Every window was
    /// rejected.
    ///
    /// At one sentence per call, merging and shifting are structurally
    /// impossible, alignment is trivially correct, and a rejection costs exactly
    /// one sentence instead of the whole window. Surrounding sentences still go
    /// in as read-only context, so the model is not working blind.
    ///
    /// The cost is one model call per sentence, which is the right trade: §13 is
    /// explicit that POLISHED must not restructure across sentence boundaries.
    public var windowSize: Int
    /// Sentences of read-only context on each side.
    public var contextSentences: Int
    public var thresholds: ValidationThresholds
    public var promptVersion: String
    /// Retry a rejected window once with stricter instructions.
    public var retryOnRejection: Bool
    /// Which language's lexicons the validator applies.
    ///
    /// Part of the parameters, so it is part of the content hash and a change
    /// re-runs POLISH rather than leaving text validated against another
    /// language's negation list.
    public var language: TranscriptLanguage

    public init(
        windowSize: Int = 1,
        contextSentences: Int = 2,
        thresholds: ValidationThresholds = .default,
        promptVersion: String = PolishPrompt.version,
        retryOnRejection: Bool = true,
        language: TranscriptLanguage = .english
    ) {
        self.windowSize = Swift.max(1, windowSize)
        self.contextSentences = Swift.max(0, contextSentences)
        self.thresholds = thresholds
        self.promptVersion = promptVersion
        self.retryOnRejection = retryOnRejection
        self.language = language
    }

    /// Lenient, so projects written before `language` existed still open.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowSize = try c.decodeIfPresent(Int.self, forKey: .windowSize) ?? 1
        contextSentences = try c.decodeIfPresent(Int.self, forKey: .contextSentences) ?? 2
        thresholds =
            try c.decodeIfPresent(ValidationThresholds.self, forKey: .thresholds) ?? .default
        promptVersion =
            try c.decodeIfPresent(String.self, forKey: .promptVersion) ?? PolishPrompt.version
        retryOnRejection = try c.decodeIfPresent(Bool.self, forKey: .retryOnRejection) ?? true
        language = try c.decodeIfPresent(TranscriptLanguage.self, forKey: .language) ?? .english
    }

    public static let `default` = PolishParameters()
}

public protocol PolishProcessing: Sendable {
    func process(
        clean: Transcript,
        parameters: PolishParameters,
        host: any LanguageModelHosting,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PolishResult
}

/// Produces the POLISHED variant (§13).
///
/// A readability transformation, never a summary. The model sees a few sentences
/// at a time and never enough to summarize, and everything it returns must
/// survive the gauntlet before it is accepted.
///
/// The failure path matters as much as the success path: a rejected window is
/// retried once with its violations named, and a second rejection keeps the CLEAN
/// text and flags the segment. Polished output is never silently accepted, and
/// never silently worse than clean.
public struct PolishProcessor: PolishProcessing {
    public let validator: any Validating

    public init(validator: any Validating = ValidationGauntlet()) {
        self.validator = validator
    }

    public func process(
        clean: Transcript,
        parameters: PolishParameters = .default,
        host: any LanguageModelHosting,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> PolishResult {
        // Segments carry timing and identity, so they are the unit of work. From
        // this engine they arrive roughly sentence-sized, which is what §14 asks
        // for, and using them directly keeps the mapping back to audio exact.
        let units = clean.segments.enumerated().filter { !$0.element.text.isEmpty }
        guard !units.isEmpty else {
            return PolishResult(transcript: clean, sentences: [])
        }

        var polishedText: [SegmentID: String] = [:]
        var records: [PolishedSentence] = []
        let windowCount = (units.count + parameters.windowSize - 1) / parameters.windowSize

        for (windowIndex, window) in units.chunked(into: parameters.windowSize).enumerated() {
            try Task.checkCancellation()
            progress(Double(windowIndex) / Double(windowCount))

            let originals = window.map(\.element.text)
            let context = Self.context(around: window, in: units,
                                       count: parameters.contextSentences)

            let outcome = await polishWindow(
                originals: originals, context: context,
                parameters: parameters, host: host)

            for (offset, unit) in window.enumerated() {
                let revised = outcome.sentences.indices.contains(offset)
                    ? outcome.sentences[offset]
                    : unit.element.text
                polishedText[unit.element.id] = revised
                records.append(PolishedSentence(
                    segmentID: unit.element.id, original: unit.element.text,
                    revised: revised, report: outcome.report,
                    disposition: outcome.disposition))
            }
        }
        progress(1)

        var segments = clean.segments
        for index in segments.indices {
            guard let revised = polishedText[segments[index].id] else { continue }
            let changed = revised != segments[index].text
            segments[index].text = revised
            if changed {
                // Word timings describe the spoken words, which no longer match
                // rewritten text. Keeping them would silently misalign subtitle
                // export, so they are dropped and the segment's own span stands.
                segments[index].words = []
            }
            if let record = records.first(where: { $0.segmentID == segments[index].id }),
               record.disposition == .fellBackToClean || record.disposition == .modelFailed {
                segments[index].warnings.append(
                    .polishFellBack(reasons: record.report.failureReasons))
            } else if records.contains(where: {
                $0.segmentID == segments[index].id && $0.disposition == .acceptedAfterRetry
            }) {
                segments[index].warnings.append(.polishRetried)
            }
        }

        let transcript = Transcript(
            variant: .polished, segments: segments,
            provenance: Provenance(
                engineID: clean.provenance.engineID,
                modelID: .systemDefault,
                promptVersion: parameters.promptVersion,
                silenceParameterHash: clean.provenance.silenceParameterHash,
                chunkParameterHash: clean.provenance.chunkParameterHash,
                concurrency: clean.provenance.concurrency))

        return PolishResult(transcript: transcript, sentences: records)
    }

    // MARK: - One window

    private struct WindowOutcome {
        let sentences: [String]
        let report: ValidationReport
        let disposition: PolishDisposition
    }

    private func polishWindow(
        originals: [String],
        context: PolishContext,
        parameters: PolishParameters,
        host: any LanguageModelHosting
    ) async -> WindowOutcome {
        // First attempt.
        do {
            let revised = try await host.rewrite(
                sentences: originals, context: context,
                instructions: PolishPrompt.instructions)
            let report = try validator.validate(
                original: originals, revised: revised,
                language: parameters.language, thresholds: parameters.thresholds)
            if report.passed {
                return WindowOutcome(sentences: revised, report: report, disposition: .accepted)
            }

            guard parameters.retryOnRejection else {
                return WindowOutcome(sentences: originals, report: report,
                                     disposition: .fellBackToClean)
            }

            // Retry, naming what went wrong.
            let retried = try await host.rewrite(
                sentences: originals, context: context,
                instructions: PolishPrompt.retryInstructions(violations: report.failureReasons))
            let retryReport = try validator.validate(
                original: originals, revised: retried,
                language: parameters.language, thresholds: parameters.thresholds)
            if retryReport.passed {
                return WindowOutcome(sentences: retried, report: retryReport,
                                     disposition: .acceptedAfterRetry)
            }
            return WindowOutcome(sentences: originals, report: retryReport,
                                 disposition: .fellBackToClean)

        } catch {
            // A model failure is not a job failure. The clean text is already
            // good prose; polish is an enhancement that can decline.
            let reason = (error as? VoxScriptaError)?.errorDescription ?? error.localizedDescription
            return WindowOutcome(
                sentences: originals,
                report: ValidationReport(results: [CheckResult(
                    check: .cardinality, passed: false, detail: reason)]),
                disposition: .modelFailed)
        }
    }

    /// Read-only sentences either side of a window.
    private static func context(
        around window: [(offset: Int, element: TranscriptSegment)],
        in units: [(offset: Int, element: TranscriptSegment)],
        count: Int
    ) -> PolishContext {
        guard count > 0, let first = window.first, let last = window.last else {
            return PolishContext()
        }
        let positions = units.map(\.offset)
        guard let start = positions.firstIndex(of: first.offset),
              let end = positions.firstIndex(of: last.offset) else { return PolishContext() }

        let before = units[Swift.max(0, start - count)..<start].map(\.element.text)
        let after = units[Swift.min(end + 1, units.count)
                          ..< Swift.min(end + 1 + count, units.count)].map(\.element.text)
        return PolishContext(preceding: Array(before), following: Array(after))
    }
}

extension Array {
    /// Splits into consecutive slices of at most `size`.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
