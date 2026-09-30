import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaBench

@Suite("Word error rate")
struct WERTests {

    @Test("Identical text scores zero")
    func perfect() {
        let r = WordErrorRate.measure(reference: "the quick brown fox",
                                      hypothesis: "the quick brown fox")
        #expect(r.rate == 0)
        #expect(r.accuracy == 1)
    }

    @Test("Substitutions, deletions and insertions are counted separately")
    func editTypes() {
        #expect(WordErrorRate.measure(reference: "a b c", hypothesis: "a x c").substitutions == 1)
        #expect(WordErrorRate.measure(reference: "a b c", hypothesis: "a c").deletions == 1)
        #expect(WordErrorRate.measure(reference: "a b c", hypothesis: "a b x c").insertions == 1)
    }

    @Test("Notation differences are not counted as errors")
    func numberNotation() {
        // The finding from the first engine run: a perfect transcription that
        // writes numbers as digits must score zero, not 30%.
        let r = WordErrorRate.measure(
            reference: "we sold five hundred units in the third quarter, up from three hundred and twelve",
            hypothesis: "We sold 500 units in the 3rd quarter, up from 312.")
        #expect(r.rate == 0, "scored \(r)")
    }

    @Test("Real content differences are still counted")
    func contentDifferences() {
        let r = WordErrorRate.measure(reference: "we sold five hundred units",
                                      hypothesis: "we sold one thousand units")
        #expect(r.rate > 0)
    }

    @Test("An empty hypothesis loses every word")
    func emptyHypothesis() {
        let r = WordErrorRate.measure(reference: "a b c d", hypothesis: "")
        #expect(r.deletions == 4)
        #expect(r.rate == 1)
    }
}
