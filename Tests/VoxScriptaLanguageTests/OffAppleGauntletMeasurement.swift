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
    private var offApple: ValidationGauntlet {
        ValidationGauntlet(similarity: .unavailable)
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
