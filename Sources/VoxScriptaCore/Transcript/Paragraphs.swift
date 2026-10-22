import Foundation

/// Breaks a transcript into paragraphs a person would want to read.
///
/// Paragraphs used to come only from the gaps *between* engine segments, which
/// works when the engine returns a segment every few seconds and fails
/// completely when it does not. Measured on the same script, Apple's
/// transcriber returns nine segments in English and one in Spanish, and a
/// hundred words arriving as one segment produced one unbroken wall of text.
///
/// The segment's `text` is always the source of the words. An earlier version
/// rebuilt the text from `words` instead, which silently discarded everything
/// CLEAN had done — the word array still held the fillers that the text no
/// longer did. Timings are consulted only to decide *where* to break, never
/// what to say.
public enum Paragraphs {

    /// Length past which a paragraph is broken at the next sentence end,
    /// whatever the pauses say.
    ///
    /// This rule does most of the work, because the pauses frequently are not
    /// there. On a real Spanish recording the engine reported a gap of
    /// exactly zero after seven of its eight sentence endings — the timings
    /// run contiguously — so a purely pause-driven rule produced one
    /// paragraph of 242 words.
    ///
    /// Eighty is a readable paragraph rather than a measured constant. It is
    /// a target, not a ceiling: the break waits for a sentence to end, so a
    /// paragraph runs longer when the speaker does, and nothing is ever cut
    /// mid-sentence to satisfy it.
    public static let maximumWords = 80

    /// The transcript split into paragraphs, in order.
    public static func split(_ transcript: Transcript,
                             using parameters: SilenceParameters = .default) -> [String] {
        let threshold = parameters.paragraphPauseThreshold
        var paragraphs: [String] = []
        var current: [String] = []
        var words = 0

        func flush() {
            let text = current.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { paragraphs.append(text) }
            current = []
            words = 0
        }

        for (index, segment) in transcript.segments.enumerated() where !segment.text.isEmpty {
            // A pause before this segment breaks, as it always did.
            if index > 0, (segment.precedingGap ?? .zero) >= threshold { flush() }

            for sentence in sentences(in: segment.text) {
                let count = TextTokenizer.tokens(sentence).count
                // Break before a sentence that would push the paragraph past
                // the target, so the paragraph ends on a completed sentence.
                if words >= maximumWords, !current.isEmpty { flush() }
                current.append(sentence)
                words += count
            }
        }
        flush()
        return paragraphs
    }

    /// Splits text at sentence terminators, keeping the terminator.
    ///
    /// A terminator only ends a sentence when whitespace or the end of the
    /// text follows it. That one condition handles the cases a naive split
    /// gets wrong: an ellipsis is a run of full stops with no space between
    /// them, so "Hello..." stays whole rather than becoming three fragments,
    /// and a leading "...my name" is not a sentence boundary either.
    ///
    /// Deliberately simple beyond that. An abbreviation followed by a space
    /// will be mistaken for a sentence end, which costs a paragraph break in
    /// the wrong place; the alternative is a tokenizer whose language has to
    /// be known here, and being wrong is only cosmetic.
    static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?…".contains(character) else { continue }
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            guard next == nil || next!.isWhitespace else { continue }
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out.append(trimmed) }
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out.isEmpty ? [text] : out
    }
}
