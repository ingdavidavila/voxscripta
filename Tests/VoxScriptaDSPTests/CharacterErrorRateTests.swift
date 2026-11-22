import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaBench

/// Whether the character metric counts correctly.
///
/// An error metric that is itself wrong is worse than no metric, because it
/// produces a number that looks like evidence. So the operation counts are
/// checked against hand-worked cases, and the invariant that they sum to the
/// edit distance is checked on every one of them.
@Suite("Character error rate")
struct CharacterErrorRateTests {

    @Test("An identical transcript scores zero")
    func identicalIsZero() {
        let r = CharacterErrorRate.measure(reference: "the quick brown fox",
                                           hypothesis: "the quick brown fox")
        #expect(r.rate == 0)
        #expect(r.substitutions == 0 && r.deletions == 0 && r.insertions == 0)
    }

    @Test("One wrong letter is one substitution")
    func oneSubstitution() {
        let r = CharacterErrorRate.measure(reference: "cat", hypothesis: "cot")
        #expect(r.substitutions == 1)
        #expect(r.deletions == 0 && r.insertions == 0)
        #expect(r.referenceCharacters == 3)
    }

    @Test("A dropped letter is one deletion, an extra one is one insertion")
    func deletionAndInsertion() {
        let dropped = CharacterErrorRate.measure(reference: "cats", hypothesis: "cat")
        #expect(dropped.deletions == 1)
        #expect(dropped.substitutions == 0 && dropped.insertions == 0)

        let extra = CharacterErrorRate.measure(reference: "cat", hypothesis: "cats")
        #expect(extra.insertions == 1)
        #expect(extra.substitutions == 0 && extra.deletions == 0)
    }

    @Test("Nothing transcribed is all deletions; nothing spoken is all insertions")
    func emptySides() {
        let silent = CharacterErrorRate.measure(reference: "hello", hypothesis: "")
        #expect(silent.deletions == 5 && silent.rate == 1)

        let invented = CharacterErrorRate.measure(reference: "", hypothesis: "hello")
        #expect(invented.insertions == 5)
        #expect(invented.referenceCharacters == 0)
        #expect(invented.rate == 1, "inventing words against silence is total error")
    }

    @Test("The operation counts always sum to the edit distance")
    func countsSumToDistance() {
        // The invariant that makes the breakdown trustworthy. Without it the
        // counts could drift from the cost and nobody would notice, because
        // only the total is ever eyeballed.
        let pairs = [
            ("the committee did not approve the budget",
             "the comittee did not aprove the budget"),
            ("vendimos quinientas unidades", "vendimos quinientas unidad"),
            ("abcdefghij", "jihgfedcba"),
            ("short", "a much longer hypothesis entirely"),
            ("", ""),
        ]
        for (reference, hypothesis) in pairs {
            let r = CharacterErrorRate.measure(reference: reference, hypothesis: hypothesis)
            let distance = editDistance(Array(CharacterErrorRate.normalize(reference, in: .english)),
                                        Array(CharacterErrorRate.normalize(hypothesis, in: .english)))
            #expect(r.substitutions + r.deletions + r.insertions == distance,
                    "\(reference) → \(hypothesis): counts \(r.substitutions + r.deletions + r.insertions) against distance \(distance)")
        }
    }

    @Test("A near-miss costs a whole word but only a fraction of the characters")
    func nearMissIsCheapAtCharacterLevel() {
        // This is the metric's entire reason for existing, so it is asserted
        // rather than described: one wrong letter in a nine-letter word is a
        // 100% word error and roughly a 10% character error, and the gap
        // between those two numbers is what tells us which kind of mistake
        // the engine made.
        let reference = "trimestre"
        let hypothesis = "trimestro"

        let wer = WordErrorRate.measure(reference: reference, hypothesis: hypothesis,
                                        language: .spanish)
        let cer = CharacterErrorRate.measure(reference: reference, hypothesis: hypothesis,
                                             language: .spanish)
        #expect(wer.rate == 1.0, "one word, wrong, is a 100% word error rate")
        #expect(cer.rate < 0.2, "the same slip should be a small character error, got \(cer.rate)")
    }

    @Test("Spoken numbers are not counted as error in either language")
    func numbersAreCanonicalized() {
        // The mistake that produced a wrong Spanish figure earlier: scoring a
        // Spanish transcript under English rules, where "quinientas" does not
        // fold to 500 and a correct transcription looks wrong.
        let english = CharacterErrorRate.measure(
            reference: "we sold five hundred units",
            hypothesis: "we sold 500 units", language: .english)
        #expect(english.rate == 0, "notation is not error, got \(english)")

        let spanish = CharacterErrorRate.measure(
            reference: "vendimos quinientas unidades",
            hypothesis: "vendimos 500 unidades", language: .spanish)
        #expect(spanish.rate == 0, "notation is not error in Spanish either, got \(spanish)")
    }

    /// A deliberately plain reference implementation, kept separate from the
    /// one under test so a shared bug cannot hide in both.
    private func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let insert = row[j - 1] + 1
                let delete = row[j] + 1
                let substitute = previous + (a[i - 1] == b[j - 1] ? 0 : 1)
                previous = row[j]
                row[j] = Swift.min(insert, delete, substitute)
            }
        }
        return row[b.count]
    }
}
