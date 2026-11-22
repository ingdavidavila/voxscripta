import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaTestSupport

/// Whether the corpus is well-formed.
///
/// These are cheap structural checks, and they exist because the expensive
/// failure here is silent: a selection that matches nothing still runs, still
/// reports, and reports that everything passed.
@Suite("Transcription corpus")
struct TranscriptionCorpusTests {

    @Test("Case names are unique")
    func namesAreUnique() {
        let names = TranscriptionCorpus.all.map(\.name)
        let duplicates = Dictionary(grouping: names, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.sorted()
        #expect(duplicates.isEmpty,
                "two cases sharing a name collapse to one row: \(duplicates)")
    }

    @Test("Case names are safe as table keys and filenames")
    func namesAreSafeKeys() {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        for name in TranscriptionCorpus.all.map(\.name) {
            #expect(name.unicodeScalars.allSatisfy(allowed.contains),
                    "\(name) is not usable as a filename or a shell argument")
        }
    }

    @Test("Condition slugs are distinct from one another")
    func slugsAreDistinct() {
        let slugs = TranscriptionCorpus.conditions.map(\.slug)
        #expect(Set(slugs).count == slugs.count,
                "two conditions sharing a slug would merge their results: \(slugs)")
    }

    @Test("The smoke selection actually selects something")
    func smokeIsNotEmpty() {
        // The bug this catches: I wrote the smoke list from guessed slugs, and a
        // name that matches nothing produces an empty run that reports success.
        let smoke = TranscriptionCorpus.smoke
        #expect(smoke.count == 5,
                "expected 5 smoke cases, got \(smoke.count): \(smoke.map(\.name))")
    }

    @Test("Every case has a non-empty reference and a stated purpose")
    func casesAreComplete() {
        for c in TranscriptionCorpus.all {
            #expect(!c.referenceText.isEmpty, "\(c.name) has no reference text")
            #expect(c.purpose.count > 20, "\(c.name) does not say what it guards")
            #expect(!c.segments.isEmpty, "\(c.name) has no segments")
            for segment in c.segments {
                #expect(!segment.passages.isEmpty,
                        "\(c.name) has an empty segment")
            }
        }
    }

    @Test("Both languages are measured under every condition")
    func conditionsCoverBothLanguages() {
        // A condition tested only in English has not been tested: the whole
        // reason the Spanish gap went unnoticed is that it was never crossed
        // with anything.
        for condition in TranscriptionCorpus.conditions {
            let matching = TranscriptionCorpus.conditioned
                .filter { $0.condition == condition }
            let languages = Set(matching.flatMap { $0.segments.map(\.scoringLanguage) })
            #expect(languages == [.english, .spanish],
                    "\(condition.name) covers \(languages), not both languages")
        }
    }

    @Test("Mixed cases are flagged and their dominant language is the majority one")
    func mixedLanguageIsHonest() {
        let mixed = TranscriptionCorpus.mixedLanguage
        #expect(mixed.allSatisfy { $0.isMixedLanguage },
                "a case in the mixed set that is not mixed is mislabelled")

        // The es-dominant case is the field bug in miniature, so its label has
        // to be right or the case proves nothing.
        let dominant = mixed.first { $0.name == "mixed_es_dominant" }
        #expect(dominant?.dominantLanguage == .spanish,
                "mixed_es_dominant must be dominated by Spanish")

        // And single-language cases must not be flagged, or the flag is noise.
        #expect(TranscriptionCorpus.conditioned.allSatisfy { !$0.isMixedLanguage })
    }

    @Test("The long cases are long, and the gapless ones have no gaps")
    func longCasesAreLong() {
        let long = TranscriptionCorpus.long
        for c in long {
            let words = c.referenceText.split(whereSeparator: \.isWhitespace).count
            // At the corpus rate this is minutes of speech, which is what it
            // takes to cross a chunk boundary at all.
            #expect(words > 300, "\(c.name) has only \(words) words")
        }

        for c in long where c.name.hasSuffix("gapless") {
            let silences = c.segments.flatMap(\.passages).map(\.trailingSilence)
            #expect(silences.allSatisfy { $0 == 0 },
                    "\(c.name) still has trailing silence, so the planner finds a comfortable cut and the hard-cut path stays untested")
        }
    }

    @Test("Accent cases name regional voices, not a repeat of the base case")
    func accentCasesAreRegional() {
        let accents = TranscriptionCorpus.accents
        #expect(accents.count == 5, "expected 5 regional voices, got \(accents.count)")
        let tags = Set(accents.flatMap { $0.segments.map(\.voiceLanguage) })
        #expect(!tags.contains("en-US"), "en-US is the baseline, not an accent case")
        #expect(!tags.contains("es-ES"), "es-ES is the baseline, not an accent case")
    }

    @Test("Rate cases sit either side of the baseline")
    func ratesBracketTheBaseline() {
        let rates = TranscriptionCorpus.rates.flatMap { $0.segments.map(\.rate) }
        #expect(rates.contains { $0 < 0.45 }, "no slow case")
        #expect(rates.contains { $0 > 0.45 }, "no fast case")
    }
}
