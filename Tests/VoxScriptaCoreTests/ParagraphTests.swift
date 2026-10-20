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

    /// Builds a segment whose words run contiguously from `start`, with an
    /// optional pause inserted before the word at `pauseBefore`.
    private func segment(_ text: String, start: MediaTime = .zero,
                         wordDuration: MediaTime = .milliseconds(300),
                         pauseBefore: Int? = nil,
                         pause: MediaTime = .seconds(2)) -> TranscriptSegment {
        var words: [Word] = []
        var cursor = start
        for (index, token) in text.split(separator: " ").enumerated() {
            if index == pauseBefore { cursor = cursor + pause }
            words.append(Word(text: String(token), originalStart: cursor,
                              originalEnd: cursor + wordDuration))
            cursor = cursor + wordDuration
        }
        return TranscriptSegment(
            originalStart: start, originalEnd: cursor, text: text, words: words)
    }

    private func paragraphs(_ segments: [TranscriptSegment]) -> [String] {
        Paragraphs.split(Transcript(variant: .verbatim, segments: segments,
                                    provenance: Provenance()))
    }

    @Test("A long pause after a sentence starts a new paragraph")
    func pauseAfterSentence() {
        let s = segment("One sentence ends here. And another begins now.", pauseBefore: 4)
        let result = paragraphs([s])
        #expect(result.count == 2)
        #expect(result.first == "One sentence ends here.")
    }

    @Test("A long pause mid-sentence does not break it")
    func pauseMidSentence() {
        // The speaker hesitated; the sentence is still one sentence.
        let s = segment("One sentence that keeps going and going here.",
                        pauseBefore: 4, pause: .milliseconds(1600))
        #expect(paragraphs([s]).count == 1)
    }

    @Test("A very long pause breaks even mid-sentence")
    func emphaticPause() {
        // Four seconds of nothing is a paragraph break whatever the
        // punctuation says — the speaker was interrupted or trailed off.
        let s = segment("One sentence that keeps going and going here",
                        pauseBefore: 4, pause: .seconds(5))
        #expect(paragraphs([s]).count == 2)
    }

    @Test("Continuous speech is still broken, at a sentence end")
    func wordCapBreaks() {
        // The case that matters most: a real recording reported a gap of
        // exactly zero after seven of its eight sentence endings, so nothing
        // pause-driven can fire. Without a length rule this is one paragraph.
        let sentence = Array(repeating: "palabra", count: 29).joined(separator: " ") + " final."
        let text = Array(repeating: sentence, count: 4).joined(separator: " ")
        let result = paragraphs([segment(text)])
        #expect(result.count > 1, "continuous speech must still be broken up")
        // And never mid-sentence: every paragraph but the last ends a sentence.
        for paragraph in result.dropLast() {
            #expect(paragraph.hasSuffix("final."), "broke mid-sentence: \(paragraph.suffix(40))")
        }
    }

    @Test("Nothing is lost or duplicated")
    func wordsArePreserved() {
        let sentence = Array(repeating: "palabra", count: 29).joined(separator: " ") + " final."
        let text = Array(repeating: sentence, count: 4).joined(separator: " ")
        let joined = paragraphs([segment(text)]).joined(separator: " ")
        #expect(joined.split(separator: " ").count == text.split(separator: " ").count)
    }

    @Test("A segment without word timings is still emitted")
    func segmentWithoutWords() {
        // Some engines return no word-level timings. The text must survive.
        let bare = TranscriptSegment(originalStart: .zero, originalEnd: .seconds(5),
                                     text: "Sin marcas de tiempo.", words: [])
        #expect(paragraphs([bare]) == ["Sin marcas de tiempo."])
    }

    @Test("An empty transcript yields no paragraphs")
    func empty() {
        #expect(paragraphs([]).isEmpty)
    }
}
