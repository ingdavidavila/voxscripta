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
/// One value carried by a ``SegmentWarning``, encoded as itself.
///
/// Exists so the wire carries `{"confidence": 0.42}` rather than
/// `{"confidence": "0.42"}`. Pre-formatting a number in the engine would
/// decide the decimal separator for every language, and Spanish writes 0,42.
public enum WarningValue: Hashable, Sendable, Codable {
    case text(String)
    case whole(Int)
    case number(Double)

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .whole(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Int before Double: a whole number decodes as either, and reading it
        // back as 2.0 would make an interface print "2.0 segments".
        if let value = try? container.decode(Int.self) { self = .whole(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .text(try container.decode(String.self)) }
    }
}

public enum SegmentWarning: Hashable, Sendable, Codable {
    /// Overlap de-duplication could not find a confident splice point.
    case mergeAmbiguity
    /// The engine reported low confidence across the segment.
    case lowConfidence(Float)
    /// This span could not be transcribed after all retries; text is a placeholder.
    case transcriptionGap
    /// Polished output failed validation and fell back to the clean text.
    case polishFellBack(reasons: [String])
    /// The transcript does not read as the language it was transcribed as.
    ///
    /// Carried on the transcript rather than thrown, because the text is still
    /// readable and the reader is better placed than the app to judge it.
    case languageLooksWrong(transcribedAs: String, detected: String)
    /// Far fewer words than the detected speech accounts for.
    case fewWordsForSpeech(words: Int, speechSeconds: Int)
    /// Polished output was accepted only after a retry.
    case polishRetried
    /// CLEAN removed this many segments for scoring below its confidence
    /// floor. A reader looking at a shorter transcript than they expected is
    /// owed the reason.
    case cleanRemovedLowConfidence(segments: Int, floor: Double)
    /// Every segment scored below CLEAN's confidence floor, so none was
    /// removed and the text stands as it was recognised.
    ///
    /// The alternative was an empty CLEAN, which is what used to happen: a
    /// blank default view, no explanation, and speech that had in fact been
    /// recognised sitting in VERBATIM next to it. The floor exists to drop
    /// isolated garbage, and "all of it scored low" is a different situation
    /// that deserves a different answer.
    case cleanKeptAllBelowFloor(segments: Int, floor: Double)

    /// A stable name for this case, for an interface to look wording up by.
    ///
    /// Engine-side wording cannot work off Apple — `String(localized:)` is
    /// absent from swift-corelibs-foundation, this project shims it to the
    /// identity function, and the shim is reached only after interpolation, so
    /// the lookup key is destroyed before any table could be consulted. That
    /// is why errors already travel as codes (see the commit that introduced
    /// ``ErrorCode``), and warnings follow them rather than inventing a second
    /// route beside the interfaces' own catalogues.
    public var code: String {
        switch self {
        case .mergeAmbiguity: "mergeAmbiguity"
        case .lowConfidence: "lowConfidence"
        case .transcriptionGap: "transcriptionGap"
        case .polishFellBack: "polishFellBack"
        case .languageLooksWrong: "languageLooksWrong"
        case .fewWordsForSpeech: "fewWordsForSpeech"
        case .polishRetried: "polishRetried"
        case .cleanRemovedLowConfidence: "cleanRemovedLowConfidence"
        case .cleanKeptAllBelowFloor: "cleanKeptAllBelowFloor"
        }
    }

    /// The case's own values, keyed by its label names.
    ///
    /// Keyed rather than positional so a catalogue interpolates by name and
    /// cannot be broken by a case gaining a value. Numbers stay numbers rather
    /// than becoming pre-formatted strings: a Spanish interface writes 0,42
    /// where an English one writes 0.42, and that is the interface's decision,
    /// not the engine's.
    public var values: [String: WarningValue] {
        switch self {
        case .mergeAmbiguity, .transcriptionGap, .polishRetried:
            [:]
        case .lowConfidence(let confidence):
            // Rounded, because widening a Float is not free: the engine
            // reports confidence as Float and `Double(0.42)` from one is
            // 0.4199999868869781. CleanProcessor already names this trap for
            // the 0.65 floor. Rounding a number is not formatting it — the
            // interface still decides the separator and the digits — but an
            // interface should not have to know about Float widening to avoid
            // printing noise.
            ["confidence": .number((Double(confidence) * 10_000).rounded() / 10_000)]
        case .polishFellBack(let reasons):
            ["reasons": .text(reasons.joined(separator: ", ")),
             "count": .whole(reasons.count)]
        case .languageLooksWrong(let transcribedAs, let detected):
            ["transcribedAs": .text(transcribedAs), "detected": .text(detected)]
        case .fewWordsForSpeech(let words, let speechSeconds):
            ["words": .whole(words), "speechSeconds": .whole(speechSeconds)]
        case .cleanRemovedLowConfidence(let segments, let floor):
            ["segments": .whole(segments), "floor": .number(floor)]
        case .cleanKeptAllBelowFloor(let segments, let floor):
            ["segments": .whole(segments), "floor": .number(floor)]
        }
    }

    /// How serious this is, 0 being the most serious.
    ///
    /// Ordered here so that no interface ranks warnings and no two interfaces
    /// can rank them differently. A banner showing one line shows the lowest
    /// number present.
    ///
    /// The order is about how wrong the transcript might be, not about how
    /// unusual the event is. `languageLooksWrong` leads because it is the only
    /// case where the text may bear no relation to the recording;
    /// `polishRetried` is last because the output was accepted and is fine.
    ///
    /// Between those two the rule is the Windows session's, and it is better
    /// than the one it replaced: **words missing outrank words doubtful.** A
    /// reader can judge text that is present and cannot judge text that is
    /// gone. My first order had `cleanKeptAllBelowFloor` second, which has it
    /// backwards — that case is the one where nothing was removed at all.
    ///
    /// The refinement on top of it is that the three missing-words cases are
    /// not equal, so they are ordered by how much is missing: most of the
    /// speech, then a span of it, then some segments of it.
    public var severity: Int {
        switch self {
        case .languageLooksWrong: 0
        case .fewWordsForSpeech: 1
        case .transcriptionGap: 2
        case .cleanRemovedLowConfidence: 3
        case .cleanKeptAllBelowFloor: 4
        case .polishFellBack: 5
        case .mergeAmbiguity: 6
        case .lowConfidence: 7
        case .polishRetried: 8
        }
    }

    /// Whether this describes the whole transcript rather than one segment.
    ///
    /// The engine answers this so that no interface has to keep its own list
    /// and no two interfaces can disagree. It is also what decides where the
    /// warning is stored: see ``Transcript/notes``.
    public var describesWholeTranscript: Bool {
        switch self {
        case .languageLooksWrong, .fewWordsForSpeech,
             .cleanRemovedLowConfidence, .cleanKeptAllBelowFloor:
            true
        case .mergeAmbiguity, .lowConfidence, .transcriptionGap,
             .polishFellBack, .polishRetried:
            false
        }
    }
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

    /// Whether a reader is offered this variant to pick, copy and save.
    ///
    /// CLEAN is not. It remains a pipeline stage — POLISH is built from it and
    /// the review screen reports on it — but it stopped being a version anyone
    /// chooses, because three names for the same recording asked the reader to
    /// care about a distinction that is the service's business and not theirs.
    ///
    /// Here rather than in each interface because it is one product decision,
    /// and an interface that disagreed would offer a variant the others hide.
    /// The consequence is worth stating where the decision is: whatever CLEAN
    /// removes is now absent from POLISHED with no CLEAN view to find it in, so
    /// `cleanRemovedLowConfidence` and `cleanKeptAllBelowFloor` are the only
    /// evidence that anything was dropped. Both are carried through to
    /// POLISHED for exactly that reason.
    public var isOfferedToReaders: Bool {
        switch self {
        case .verbatim, .polished: true
        case .clean: false
        }
    }

    /// The variants a reader can choose between, in the order they are shown.
    public static var offeredToReaders: [TranscriptVariant] {
        allCases.filter(\.isOfferedToReaders)
    }
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

    /// What the pipeline noticed about the recording as a whole.
    ///
    /// Separate from a segment's `warnings` because the two are different
    /// claims, and storing one as the other cost a real defect. The
    /// wrong-language note was appended to `segments[0].warnings` — `warnings`
    /// being a segment field and nothing else existing — and CLEAN then
    /// deleted that segment for scoring below its confidence floor, taking the
    /// note with it. On one recording CLEAN dropped every segment and handed
    /// back an empty transcript with no warning at all.
    ///
    /// The selection was not bad luck, which is the part worth remembering.
    /// Decoding speech against the wrong language is *what produces* low
    /// confidence, so the note was pinned to precisely the segment that the
    /// condition it describes was most likely to remove. Found by the Windows
    /// session running real audio in both directions.
    ///
    /// Joins the contract defaulted-empty, so every transcript written before
    /// this decodes unchanged — and every writer populates it, because an
    /// empty one that a live writer forgot would look exactly like a
    /// recording with nothing to report. The merger starts it, and CLEAN and
    /// POLISH carry it forward: a note about the recording is true of every
    /// variant derived from that recording.
    public var notes: [SegmentWarning]

    public init(variant: TranscriptVariant, segments: [TranscriptSegment],
                provenance: Provenance, notes: [SegmentWarning] = []) {
        self.variant = variant
        self.segments = segments
        self.provenance = provenance
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case variant, segments, provenance, notes
    }

    /// Written by hand for one reason: Swift's synthesised decoder does not
    /// apply a property's default value to a missing key, so adding `notes`
    /// with the synthesised one would have failed to read every project on
    /// disk.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variant = try c.decode(TranscriptVariant.self, forKey: .variant)
        segments = try c.decode([TranscriptSegment].self, forKey: .segments)
        provenance = try c.decode(Provenance.self, forKey: .provenance)
        notes = try c.decodeIfPresent([SegmentWarning].self, forKey: .notes) ?? []
    }

    public var isEmpty: Bool { segments.isEmpty }
    /// How many words the transcript contains.
    ///
    /// Counted from the text, not from the per-word timings, and the
    /// distinction is not academic. POLISH empties the timing array for every
    /// sentence it rewrites — the timings describe the spoken words and the
    /// rewritten text no longer matches them — so counting timings counted
    /// only the sentences polish happened to leave alone.
    ///
    /// On a real recording that read 13 against the 38 words actually in the
    /// file, and every caller of this is a display string: "1,702 words" under
    /// the variant picker, "Copied 13 words" after a copy, the footer of a
    /// Markdown export. All of them want the number a reader would get by
    /// counting.
    public var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

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
    /// The transcript as readable prose, broken into paragraphs.
    ///
    /// Breaks come from the pauses the speaker actually left, found in the
    /// word timings, rather than from wherever the engine happened to end a
    /// segment. See ``Paragraphs`` — a segment per sentence and a segment per
    /// hundred words are both normal, and only one of them produces readable
    /// text without this.
    public func plainText(using p: SilenceParameters = .default) -> String {
        Paragraphs.split(self, using: p).joined(separator: "\n\n")
    }
}
