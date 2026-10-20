import Foundation

/// Breaks a transcript into paragraphs a person would want to read.
///
/// Paragraphs used to come only from the gaps *between* engine segments, which
/// works when the engine returns a segment every few seconds and fails
/// completely when it does not. Measured on the same script, Apple's
/// transcriber returns nine segments in English and one in Spanish, and a
/// hundred words arriving as one segment produced one unbroken wall of text.
///
/// The pauses are still there — they are just inside the segment rather than
/// between two of them — and word-level timings expose them. So the break
/// points come from the words, and segment boundaries are merely one more
/// place a pause can happen.
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

    /// A pause this much longer than the threshold breaks a paragraph even
    /// mid-sentence.
    ///
    /// Speech does not always end a sentence before a long silence — the
    /// speaker is interrupted, or trails off and restarts. Four seconds of
    /// nothing is a paragraph break whatever the punctuation says.
    public static let emphaticPauseFactor = 2.5

    /// The transcript split into paragraphs, in order.
    public static func split(_ transcript: Transcript,
                             using parameters: SilenceParameters = .default) -> [String] {
        let threshold = parameters.paragraphPauseThreshold
        let emphatic = threshold * emphaticPauseFactor

        var paragraphs: [String] = []
        var current: [String] = []
        var wordsInParagraph = 0

        func flush() {
            let text = current.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { paragraphs.append(text) }
            current = []
            wordsInParagraph = 0
        }

        var previousEnd: MediaTime?

        for (index, segment) in transcript.segments.enumerated() {
            guard !segment.text.isEmpty else { continue }

            // A segment with no word timings cannot be split internally, so it
            // is treated as one block and only its leading gap can break.
            guard !segment.words.isEmpty else {
                let gap = segment.precedingGap ?? .zero
                if index > 0, gap >= threshold { flush() }
                current.append(segment.text)
                wordsInParagraph += TextTokenizer.tokens(segment.text).count
                previousEnd = segment.originalEnd
                continue
            }

            for word in segment.words {
                let gap = previousEnd.map { word.originalStart - $0 } ?? .zero
                let endsSentence = current.last.map(Self.closesSentence) ?? false

                let breaks: Bool
                if previousEnd == nil {
                    breaks = false
                } else if gap >= emphatic {
                    // Long enough that the punctuation does not get a vote.
                    breaks = true
                } else if gap >= threshold, endsSentence {
                    breaks = true
                } else if wordsInParagraph >= maximumWords, endsSentence {
                    breaks = true
                } else {
                    breaks = false
                }

                if breaks { flush() }
                current.append(word.text)
                wordsInParagraph += 1
                previousEnd = word.originalEnd
            }
        }
        flush()
        return paragraphs
    }

    /// Whether a token ends a sentence.
    ///
    /// Spanish opens questions with `¿` and closes them with `?`, so only the
    /// trailing mark counts; an opening mark is the start of a sentence, not
    /// the end of one.
    static func closesSentence(_ token: String) -> Bool {
        guard let last = token.last(where: { !$0.isWhitespace }) else { return false }
        return ".!?…".contains(last)
    }
}
