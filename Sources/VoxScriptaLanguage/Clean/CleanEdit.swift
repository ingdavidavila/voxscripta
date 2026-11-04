import Foundation
import VoxScriptaCore

/// One change CLEAN made, recorded so the result can be audited.
///
/// The whole argument for CLEAN is that it carries no hallucination risk. That
/// claim is only worth anything if it can be checked, so every edit is logged
/// with what it replaced. The UI can show them; the test suite asserts over them.
public struct CleanEdit: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// A non-lexical filler was deleted.
        case disfluencyRemoved
        /// An immediate stutter repetition was collapsed to one occurrence.
        case repetitionCollapsed
        /// Doubled or stranded punctuation was repaired.
        case punctuationRepaired
        /// A sentence-initial letter was capitalized.
        case capitalized
        /// Redundant whitespace was normalized.
        case whitespaceNormalized
        /// A terminal full stop was added before a long pause.
        case sentenceTerminated
        /// A whole segment was dropped for scoring below the confidence floor.
        ///
        /// The only edit that removes a sentence rather than a word, which is
        /// why it is logged with its full text and its score: the verbatim
        /// transcript still holds it, and this says exactly what was taken out
        /// of the clean one and on what evidence.
        case lowConfidenceDropped
    }

    public let segmentID: SegmentID
    public let kind: Kind
    public let original: String
    public let replacement: String
    /// Where in the recording the edit applies, for the UI to jump to.
    public let at: MediaTime?

    public init(segmentID: SegmentID, kind: Kind, original: String,
                replacement: String, at: MediaTime? = nil) {
        self.segmentID = segmentID
        self.kind = kind
        self.original = original
        self.replacement = replacement
        self.at = at
    }
}

/// A CLEAN transcript together with the record of how it was produced.
public struct CleanResult: Sendable {
    public let transcript: Transcript
    public let edits: [CleanEdit]

    public init(transcript: Transcript, edits: [CleanEdit]) {
        self.transcript = transcript
        self.edits = edits
    }

    public func edits(of kind: CleanEdit.Kind) -> [CleanEdit] {
        edits.filter { $0.kind == kind }
    }

    /// How many words CLEAN removed.
    public var wordsRemoved: Int {
        edits.count { $0.kind == .disfluencyRemoved || $0.kind == .repetitionCollapsed }
    }

    /// How many segments the confidence floor discarded.
    public var segmentsDropped: Int {
        edits.count { $0.kind == .lowConfidenceDropped }
    }
}
