import Testing
import Foundation
@testable import VoxScriptaCore

/// Paragraph structure.
///
/// Breaks used to come only from the gaps between engine segments, which works
/// when the engine returns one every few seconds and fails entirely when it
/// does not — a hundred words arriving as a single segment produced one
/// unbroken wall of text.
@Suite("Paragraphs")
struct ParagraphTests {

    private func segment(_ text: String, gap: MediaTime? = nil) -> TranscriptSegment {
        TranscriptSegment(originalStart: .zero, originalEnd: .seconds(5),
                          text: text, words: [], precedingGap: gap)
    }

    private func paragraphs(_ segments: [TranscriptSegment]) -> [String] {
        Paragraphs.split(Transcript(variant: .verbatim, segments: segments,
                                    provenance: Provenance()))
    }

    @Test("The segment's text is the source, not its words")
    func textWins() {
        // CLEAN edits `text` and leaves `words` alone, so rebuilding the
        // paragraph from the word array would reinstate every filler it had
        // just removed. That regression is what this test exists for.
        var s = segment("So we start Monday.")
        s.words = [Word(text: "uh", originalStart: .zero, originalEnd: .milliseconds(200)),
                   Word(text: "so", originalStart: .milliseconds(200),
                        originalEnd: .milliseconds(400))]
        #expect(paragraphs([s]) == ["So we start Monday."])
    }

    @Test("A long pause between segments starts a new paragraph")
    func pauseBetweenSegments() {
        let result = paragraphs([segment("First part."),
                                 segment("Second part.", gap: .seconds(3))])
        #expect(result.count == 2)
    }

    @Test("A short gap between segments does not")
    func shortGapJoins() {
        let result = paragraphs([segment("First part."),
                                 segment("Second part.", gap: .milliseconds(200))])
        #expect(result == ["First part. Second part."])
    }

    @Test("Continuous speech is still broken, at a sentence end")
    func lengthRuleBreaks() {
        // The case that matters most: on a real recording the engine reported
        // a gap of exactly zero after seven of its eight sentence endings, so
        // nothing pause-driven can fire. Without a length rule this is one
        // paragraph.
        let sentence = Array(repeating: "palabra", count: 29).joined(separator: " ") + " final."
        let result = paragraphs([segment(Array(repeating: sentence, count: 4)
                                             .joined(separator: " "))])
        #expect(result.count > 1, "continuous speech must still be broken up")
        for paragraph in result {
            #expect(paragraph.hasSuffix("final."), "broke mid-sentence: \(paragraph.suffix(30))")
        }
    }

    @Test("Nothing is lost or duplicated")
    func wordsPreserved() {
        let sentence = Array(repeating: "palabra", count: 29).joined(separator: " ") + " final."
        let text = Array(repeating: sentence, count: 4).joined(separator: " ")
        let joined = paragraphs([segment(text)]).joined(separator: " ")
        #expect(joined.split(separator: " ").count == text.split(separator: " ").count)
    }

    @Test("A single short segment is one paragraph")
    func shortSegment() {
        #expect(paragraphs([segment("Sin marcas de tiempo.")]) == ["Sin marcas de tiempo."])
    }

    @Test("An empty transcript yields no paragraphs")
    func empty() {
        #expect(paragraphs([]).isEmpty)
    }
}

@Suite("Sentence splitting")
struct SentenceSplitTests {

    @Test("An ellipsis is not three sentences")
    func ellipsis() {
        // A terminator only ends a sentence when whitespace follows it.
        #expect(Paragraphs.sentences(in: "Hello...") == ["Hello..."])
        #expect(Paragraphs.sentences(in: "...my name is David.") == ["...my name is David."])
    }

    @Test("Ordinary sentences split")
    func ordinary() {
        #expect(Paragraphs.sentences(in: "One. Two! Three?") == ["One.", "Two!", "Three?"])
    }

    @Test("Text with no terminator is one sentence")
    func unterminated() {
        #expect(Paragraphs.sentences(in: "no full stop here") == ["no full stop here"])
    }

    @Test("A decimal is not a sentence end")
    func decimals() {
        // No space after the point, so it does not split.
        #expect(Paragraphs.sentences(in: "We sold 1.500 units.") == ["We sold 1.500 units."])
    }
}
