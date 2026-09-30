import Foundation

/// A single recognized word with its timing on the original timeline.
public struct Word: Hashable, Sendable, Codable {
    public let text: String
    public let originalStart: MediaTime
    public let originalEnd: MediaTime
    public let confidence: Float?

    public init(text: String, originalStart: MediaTime, originalEnd: MediaTime, confidence: Float? = nil) {
        self.text = text
        self.originalStart = originalStart
        self.originalEnd = originalEnd
        self.confidence = confidence
    }

    public var range: TimeRange { TimeRange(start: originalStart, end: originalEnd) }
}

/// Something the pipeline noticed about a segment that the user should be able to see.
///
/// Warnings are surfaced in the UI rather than swallowed. A transcript that
/// quietly hides an ambiguous merge is worse than one that marks it.
public enum SegmentWarning: Hashable, Sendable, Codable {
    /// Overlap de-duplication could not find a confident splice point.
    case mergeAmbiguity
    /// The engine reported low confidence across the segment.
    case lowConfidence(Float)
    /// This span could not be transcribed after all retries; text is a placeholder.
    case transcriptionGap
    /// Polished output failed validation and fell back to the clean text.
    case polishFellBack(reasons: [String])
    /// Polished output was accepted only after a retry.
    case polishRetried
}

/// The unit of the transcript data model.
///
/// Transcripts are never stored as one string. This structure is what makes
/// timestamps, speaker labels, subtitle export, and per-sentence provenance
/// possible without re-deriving anything.
public struct TranscriptSegment: Hashable, Sendable, Codable, Identifiable {
    public let id: SegmentID
    /// Which work unit produced this. Nil for segments synthesized during merge.
    public let chunkID: ChunkID?
    public var originalStart: MediaTime
    public var originalEnd: MediaTime
    /// Always nil in V1. The §30 slot, present from day one so that adding
    /// diarization later populates a field the exports already understand.
    public var speaker: SpeakerID?
    public var text: String
    public var words: [Word]
    public var confidence: Float?
    /// Silence immediately before this segment. Drives paragraph breaks.
    public var precedingGap: MediaTime?
    public var warnings: [SegmentWarning]

    public init(
        id: SegmentID = SegmentID(),
        chunkID: ChunkID? = nil,
        originalStart: MediaTime,
        originalEnd: MediaTime,
        speaker: SpeakerID? = nil,
        text: String,
        words: [Word] = [],
        confidence: Float? = nil,
        precedingGap: MediaTime? = nil,
        warnings: [SegmentWarning] = []
    ) {
        self.id = id
        self.chunkID = chunkID
        self.originalStart = originalStart
        self.originalEnd = originalEnd
        self.speaker = speaker
        self.text = text
        self.words = words
        self.confidence = confidence
        self.precedingGap = precedingGap
        self.warnings = warnings
    }

    public var range: TimeRange { TimeRange(start: originalStart, end: originalEnd) }

    /// Whether this segment should start a new paragraph, given the pause thresholds.
    public func startsParagraph(using p: SilenceParameters) -> Bool {
        guard let gap = precedingGap else { return false }
        return gap >= p.paragraphPauseThreshold
    }
}

/// Which of the three outputs a transcript represents (§11–13).
public enum TranscriptVariant: String, Sendable, Codable, CaseIterable {
    /// Exactly what was said, disfluencies included. No transformation.
    case verbatim
    /// Readability improvements from deterministic rules. No model involved.
    case clean
    /// LLM readability pass, validated sentence by sentence.
    case polished
}

/// What produced a transcript, recorded so results are reproducible and auditable.
public struct Provenance: Hashable, Sendable, Codable {
    public let engineID: EngineID?
    public let modelID: ModelID?
    public let promptVersion: String?
    public let silenceParameterHash: String?
    public let chunkParameterHash: String?
    /// Chunks in flight when this transcript was produced.
    ///
    /// Recorded because engine output is deterministic at a fixed concurrency but
    /// not across values, so resuming at a different setting can shift a word.
    public let concurrency: Int?
    public let generatedAt: Date
    public let appVersion: String

    public init(
        engineID: EngineID? = nil,
        modelID: ModelID? = nil,
        promptVersion: String? = nil,
        silenceParameterHash: String? = nil,
        chunkParameterHash: String? = nil,
        concurrency: Int? = nil,
        generatedAt: Date = Date(),
        appVersion: String = VoxScripta.version
    ) {
        self.engineID = engineID
        self.modelID = modelID
        self.promptVersion = promptVersion
        self.silenceParameterHash = silenceParameterHash
        self.chunkParameterHash = chunkParameterHash
        self.concurrency = concurrency
        self.generatedAt = generatedAt
        self.appVersion = appVersion
    }
}

/// One complete transcript in one variant.
public struct Transcript: Sendable, Codable {
    public let variant: TranscriptVariant
    public var segments: [TranscriptSegment]
    public let provenance: Provenance

    public init(variant: TranscriptVariant, segments: [TranscriptSegment], provenance: Provenance) {
        self.variant = variant
        self.segments = segments
        self.provenance = provenance
    }

    public var isEmpty: Bool { segments.isEmpty }
    public var wordCount: Int { segments.reduce(0) { $0 + $1.words.count } }

    /// The span from the first segment's start to the last segment's end.
    public var timeRange: TimeRange? {
        guard let f = segments.first, let l = segments.last else { return nil }
        return TimeRange(start: f.originalStart, end: l.originalEnd)
    }

    /// Segments must be ordered and non-overlapping on the original timeline.
    /// The merger asserts this; exports rely on it.
    public var isMonotonic: Bool {
        zip(segments, segments.dropFirst()).allSatisfy { $0.originalEnd <= $1.originalStart }
    }

    /// Plain text with paragraph breaks derived from measured pauses.
    public func plainText(using p: SilenceParameters = .default) -> String {
        var out = ""
        for (i, seg) in segments.enumerated() {
            if i > 0 { out += seg.startsParagraph(using: p) ? "\n\n" : " " }
            out += seg.text
        }
        return out
    }
}
