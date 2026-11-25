import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaTranscription

/// Whisper's sub-word pieces, assembled into words.
///
/// Every case here is a real one. They come from a five-minute English
/// recording run on Windows with the base and small models, which produced
/// "nov ice", "sub red dit", "code c ad emy", "20, 000" and "100 %". The
/// pieces below are written the way Whisper emits them — **leading space
/// means a new word** — because that is the signal the old code threw away.
@Suite("Whisper word assembly")
struct WhisperWordAssemblyTests {

    private func piece(_ text: String, _ start: Double, _ end: Double,
                       _ confidence: Float = 0.9) -> WhisperEngine.Piece {
        WhisperEngine.Piece(text: text,
                            start: .seconds(start),
                            end: .seconds(end),
                            confidence: confidence)
    }

    private func texts(_ pieces: [WhisperEngine.Piece]) -> [String] {
        WhisperEngine.assemble(pieces).map(\.text)
    }

    @Test("A continuation piece joins the word before it")
    func continuationJoins() {
        // Reported as "nov ice".
        #expect(texts([piece(" nov", 0, 0.2), piece("ice", 0.2, 0.4)]) == ["novice"])
        // Reported as "gur us".
        #expect(texts([piece(" gur", 1, 1.2), piece("us", 1.2, 1.4)]) == ["gurus"])
    }

    @Test("A leading space starts a new word")
    func spaceSeparates() {
        #expect(texts([piece(" the", 0, 0.1), piece(" programming", 0.1, 0.5)])
                == ["the", "programming"])
    }

    @Test("Five pieces make one word, not five")
    func manyPiecesOneWord() {
        // Reported as "code c ad emy".
        let pieces = [piece(" code", 0, 0.2), piece("c", 0.2, 0.3),
                      piece("ad", 0.3, 0.4), piece("emy", 0.4, 0.6)]
        #expect(texts(pieces) == ["Codecademy".lowercased()])
    }

    @Test("A number keeps its grouping comma")
    func numbersStayWhole() {
        // Reported as "20, 000". The comma has no leading space, so it was
        // never a separate word; CleanProcessor then attached it leftwards and
        // spaced the digits that followed.
        #expect(texts([piece(" 20", 0, 0.2), piece(",", 0.2, 0.25),
                       piece("000", 0.25, 0.5)]) == ["20,000"])
    }

    @Test("A percent sign stays with its number")
    func percentStays() {
        // Reported as "100 %".
        #expect(texts([piece(" 100", 0, 0.2), piece("%", 0.2, 0.3)]) == ["100%"])
    }

    @Test("A hyphenated compound stays one word")
    func hyphensHold() {
        // Reported as "full - st ack" on the base model.
        let pieces = [piece(" full", 0, 0.2), piece("-", 0.2, 0.25),
                      piece("st", 0.25, 0.4), piece("ack", 0.4, 0.6)]
        #expect(texts(pieces) == ["full-stack"])
    }

    @Test("A word's span covers its pieces and its confidence is their mean")
    func timingAndConfidence() throws {
        // The span has to grow with the word, or a subtitle cue would end
        // where the first piece ended and clip the rest of the word.
        let words = WhisperEngine.assemble([
            piece(" nov", 1.0, 1.2, 0.6), piece("ice", 1.2, 1.5, 0.8)])
        let word = try #require(words.first)
        #expect(word.originalStart == .seconds(1.0))
        #expect(word.originalEnd == .seconds(1.5))
        #expect(word.confidence.map { abs($0 - 0.7) < 0.0001 } == true)
    }

    @Test("Nothing in, nothing out")
    func emptyInput() {
        #expect(WhisperEngine.assemble([]).isEmpty)
        #expect(WhisperEngine.assemble([piece("   ", 0, 0.1)]).isEmpty)
    }

    @Test("A newline between pieces also starts a word")
    func newlineSeparates() {
        #expect(texts([piece(" one", 0, 0.2), piece("\ntwo", 0.2, 0.4)])
                == ["one", "two"])
    }
}
