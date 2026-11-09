import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// How well the gauntlet holds when the embedding is gone.
///
/// The question this answers is the one that has been an opinion until now:
/// POLISH off Apple keeps the lexical polarity count and loses the semantic
/// distance check. Spanish was measured safe in that configuration. English
/// never was, and English negation is the harder shape.
///
/// Run on a Mac with `SemanticSimilarity.unavailable`, which makes the check
/// abstain exactly as it does on Windows, Linux and Android. Measuring it any
/// other way would be measuring this machine instead of that one.
///
/// These tests print their counts. The numbers are the point; the assertions
/// only pin what has been decided on the strength of them.
@Suite("Off-Apple gauntlet measurement", .serialized)
struct OffAppleGauntletMeasurement {

    /// The gauntlet as it exists on Windows, Linux and Android.
    ///
    /// Both halves. This used to pass only `similarity: .unavailable`, while
    /// the comment above claimed it abstained "exactly as it does on Windows,
    /// Linux and Android" — and it did not, because off Apple the name tagger
    /// is gone too. Simulating one half and asserting about both is how the
    /// renamed-person hole below stayed invisible on this machine until a
    /// real Linux run found it.
    private var offApple: ValidationGauntlet {
        ValidationGauntlet(similarity: .unavailable, recognizesNames: false)
    }

    /// The gauntlet as it exists on a Mac.
    private var onApple: ValidationGauntlet { ValidationGauntlet() }

    private func escaped(
        _ cases: [EnglishRejectionCorpus.Case],
        through gauntlet: ValidationGauntlet
    ) throws -> [String] {
        var out: [String] = []
        for item in cases {
            let report = try gauntlet.validate(
                original: [item.original], revised: [item.revised], language: .english)
            if report.passed { out.append("\(item.note): “\(item.revised)”") }
        }
        return out
    }

    // MARK: - English

    @Test("English, on Apple: every corruption is caught")
    func englishOnApple() throws {
        let leaks = try escaped(EnglishRejectionCorpus.allCorruptions, through: onApple)
        print("""

        ENGLISH · on Apple (both defences)
          corruptions: \(EnglishRejectionCorpus.allCorruptions.count)
          escaped:     \(leaks.count)
        """)
        for leak in leaks { print("    ⚠︎ \(leak)") }
        #expect(leaks.isEmpty, "corruptions that escaped on Apple: \(leaks)")
    }

    @Test("English, off Apple: measured")
    func englishOffApple() throws {
        let plain = try escaped(EnglishRejectionCorpus.plainNegation, through: offApple)
        let oblique = try escaped(EnglishRejectionCorpus.obliqueNegation, through: offApple)
        let other = try escaped(EnglishRejectionCorpus.otherCorruptions, through: offApple)

        print("""

        ENGLISH · off Apple (lexical only)
          plain negation:   \(EnglishRejectionCorpus.plainNegation.count - plain.count)\
        /\(EnglishRejectionCorpus.plainNegation.count) caught
          oblique negation: \(EnglishRejectionCorpus.obliqueNegation.count - oblique.count)\
        /\(EnglishRejectionCorpus.obliqueNegation.count) caught
          other:            \(EnglishRejectionCorpus.otherCorruptions.count - other.count)\
        /\(EnglishRejectionCorpus.otherCorruptions.count) caught
        """)
        for leak in plain + oblique + other { print("    ⚠︎ \(leak)") }

        // Asserted now, because the measurement has an answer. It did not
        // start here: with the lexicon as it was, seven of twenty-nine got
        // through and all seven were negation spelled without a negative
        // word. The lexicon was extended until this held, and this test is
        // what stops it quietly regressing.
        #expect(plain.isEmpty, "plain negation escaped: \(plain)")
        #expect(oblique.isEmpty, "oblique negation escaped: \(oblique)")
        #expect(other.isEmpty, "other corruptions escaped: \(other)")
    }

    @Test("English: legitimate rewrites survive without the embedding")
    func englishLegitimateOffApple() throws {
        var blocked: [String] = []
        for item in EnglishRejectionCorpus.legitimate {
            let report = try offApple.validate(
                original: [item.original], revised: [item.revised], language: .english)
            if !report.passed { blocked.append("\(item.note): \(report.failureReasons)") }
        }
        print("""

        ENGLISH · off Apple, legitimate rewrites
          allowed: \(EnglishRejectionCorpus.legitimate.count - blocked.count)\
        /\(EnglishRejectionCorpus.legitimate.count)
        """)
        for item in blocked { print("    ⚠︎ \(item)") }
        // A gauntlet that refuses everything is useless rather than safe.
        #expect(blocked.isEmpty, "legitimate rewrites blocked: \(blocked)")
    }

    // MARK: - Names, which the embedding never guarded

    @Test("Off Apple, a renamed person at the start of a sentence is not caught")
    func renamedPersonEscapesOffApple() throws {
        // Recorded rather than asserted away, because it is a real gap and
        // the decision about closing it has not been made.
        //
        // The mechanism is narrow. Off Apple the vocabulary comes from
        // `capitalizedTokens` alone, and that deliberately skips
        // sentence-initial capitals — CLEAN and POLISHED both legitimately
        // capitalize there, so a capital in that position says nothing about
        // whether a word is a name. "Sarah Chen" to "Rebecca Chen" changes
        // only the sentence-initial word; "Chen" is watched and unchanged, so
        // the counts match and the rewrite passes.
        //
        // So the check is not blind off Apple. It is blind to proper nouns in
        // one position. A portable fix exists — treat a sentence-initial
        // capital as a name when the token after it is also capitalized,
        // which is "Sarah Chen" and is not "We shipped" — and it is a change
        // to what the product rejects, so it is not being made here.
        let report = try offApple.validate(
            original: ["Sarah Chen approved the plan."],
            revised: ["Rebecca Chen approved the plan."],
            language: .english)

        withKnownIssue("a sentence-initial proper noun is unwatched without the name tagger") {
            #expect(!report.passed, "the rename should have been caught")
        }

        // What does hold off Apple: the same rename away from the start of a
        // sentence is caught, which is what makes the gap positional rather
        // than total.
        let midSentence = try offApple.validate(
            original: ["The plan was approved by Sarah Chen."],
            revised: ["The plan was approved by Rebecca Chen."],
            language: .english)
        #expect(!midSentence.passed,
                "a rename away from the sentence start must still be caught")
    }

    // MARK: - Spanish, checked a second time

    @Test("Spanish, off Apple: the original claim re-measured")
    func spanishOffApple() throws {
        var leaks: [String] = []
        for item in SpanishRejectionCorpus.corruptions {
            let report = try offApple.validate(
                original: [item.original], revised: [item.revised], language: .spanish)
            if report.passed { leaks.append("\(item.note): “\(item.revised)”") }
        }
        print("""

        SPANISH · off Apple (lexical only)
          corruptions: \(SpanishRejectionCorpus.corruptions.count)
          escaped:     \(leaks.count)
        """)
        for leak in leaks { print("    ⚠︎ \(leak)") }
        // Spanish already runs this way on a Mac, because the embedding is
        // blind to Spanish negation. Removing it should change nothing, and
        // if it does, the claim the stage was enabled on was wrong.
        #expect(leaks.isEmpty, "Spanish corruptions that escaped: \(leaks)")
    }

    @Test("Spanish: the embedding was never doing the work")
    func spanishEmbeddingAddsNothing() throws {
        var differences: [String] = []
        for item in SpanishRejectionCorpus.corruptions {
            let withModel = try onApple.validate(
                original: [item.original], revised: [item.revised], language: .spanish)
            let without = try offApple.validate(
                original: [item.original], revised: [item.revised], language: .spanish)
            if withModel.passed != without.passed {
                differences.append(item.note)
            }
        }
        print("""

        SPANISH · cases where the embedding changed the verdict: \(differences.count)
        """)
        // The structural claim behind enabling Spanish at all: its embedding
        // does not encode negation, so its presence or absence is irrelevant.
        #expect(differences.isEmpty,
                "the embedding changed the outcome for: \(differences)")
    }
}
