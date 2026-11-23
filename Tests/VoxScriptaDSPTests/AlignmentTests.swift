import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaBench

/// Which words differed, and how.
///
/// Worth testing because the alignment is the part a person acts on. A rate is
/// a number nobody can argue with; "quarter heard as courter" is a claim about
/// two specific words, and if the backtrace is wrong it will be a confident
/// claim about the wrong ones.
@Suite("Alignment")
struct AlignmentTests {

    private func ops(_ reference: String, _ hypothesis: String) -> [Alignment.Operation] {
        Alignment.align(reference: reference.split(separator: " ").map(String.init),
                        hypothesis: hypothesis.split(separator: " ").map(String.init))
    }

    @Test("Identical transcripts are all matches")
    func identical() {
        let result = ops("the quick brown fox", "the quick brown fox")
        #expect(result.count == 4)
        #expect(result.allSatisfy { $0.isMatch })
    }

    @Test("A substitution names both words")
    func substitution() {
        let result = ops("in the third quarter", "in the third courter")
        #expect(result.filter { !$0.isMatch }.count == 1)
        #expect(result.contains(.substitution(reference: "quarter", hypothesis: "courter")))
    }

    @Test("A dropped word is a deletion and an added one an insertion")
    func deletionAndInsertion() {
        #expect(ops("near the river bank", "near the bank")
            .contains(.deletion("river")))
        #expect(ops("near the bank", "near the river bank")
            .contains(.insertion("river")))
    }

    @Test("The operations reconstruct both sides in order")
    func reconstructsBothSides() {
        // The invariant that makes the list trustworthy. A backtrace that
        // dropped or reordered a step would still produce plausible-looking
        // pairs, and nothing else here would catch it.
        let reference = "the committee did not approve the revised budget"
        let hypothesis = "the comittee did not approve a revised budget today"
        let result = ops(reference, hypothesis)

        var rebuiltReference: [String] = []
        var rebuiltHypothesis: [String] = []
        for operation in result {
            switch operation {
            case .match(let word):
                rebuiltReference.append(word); rebuiltHypothesis.append(word)
            case .substitution(let r, let h):
                rebuiltReference.append(r); rebuiltHypothesis.append(h)
            case .deletion(let word):
                rebuiltReference.append(word)
            case .insertion(let word):
                rebuiltHypothesis.append(word)
            }
        }
        #expect(rebuiltReference == reference.split(separator: " ").map(String.init))
        #expect(rebuiltHypothesis == hypothesis.split(separator: " ").map(String.init))
    }

    @Test("The operation counts agree with the rate")
    func agreesWithTheRate() {
        // Two implementations of the same quantity, so a disagreement means
        // one of them is wrong and the report would contradict its own list.
        let pairs = [
            ("the weather turned cold before the end of the week",
             "the whether turned cold before an end of the weak"),
            ("we sold five hundred units", "we sold units"),
            ("", "something appeared"),
            ("something vanished", ""),
        ]
        for (reference, hypothesis) in pairs {
            let result = ops(reference, hypothesis)
            let rate = WordErrorRate.measure(
                reference: reference.split(separator: " ").map(String.init),
                hypothesis: hypothesis.split(separator: " ").map(String.init))
            var subs = 0, dels = 0, ins = 0
            for operation in result {
                switch operation {
                case .substitution: subs += 1
                case .deletion: dels += 1
                case .insertion: ins += 1
                case .match: break
                }
            }
            #expect(subs == rate.substitutions, "substitutions disagree on \(reference)")
            #expect(dels == rate.deletions, "deletions disagree on \(reference)")
            #expect(ins == rate.insertions, "insertions disagree on \(reference)")
        }
    }

    @Test("Differences carry the words before them")
    func differencesCarryContext() {
        // Context is what makes a difference actionable rather than a riddle.
        let result = ops("the weather turned cold before the end of the week",
                         "the weather turned cold before the end of the weak")
        let differences = Alignment.differences(result)
        #expect(differences.count == 1)
        #expect(differences[0].kind == "substitution")
        #expect(differences[0].text.contains("week → weak"))
        #expect(differences[0].text.contains("of the"), "no context: \(differences[0].text)")
    }

    @Test("Spoken numbers are folded before aligning")
    func notationIsNotADifference() {
        // Otherwise a correct transcription that writes 500 where the script
        // says "five hundred" would be reported as three errors a person would
        // then go looking for.
        let differences = Alignment.differences(
            Alignment.align(reference: "we sold five hundred units",
                            hypothesis: "we sold 500 units", language: .english))
        #expect(differences.isEmpty, "got \(differences.map(\.text))")
    }
}
