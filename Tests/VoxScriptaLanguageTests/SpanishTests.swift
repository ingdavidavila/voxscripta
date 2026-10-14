import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

@Suite("Spanish language support")
struct SpanishTests {

    @Test("A locale maps to the language its lexicons are written in",
          arguments: [("es-ES", TranscriptLanguage.spanish), ("es-MX", .spanish),
                      ("es", .spanish), ("en-US", .english), ("EN-gb", .english)])
    func localeMapping(identifier: String, expected: TranscriptLanguage) {
        #expect(TranscriptLanguage(localeIdentifier: identifier) == expected)
    }

    @Test("A language without lexicons is refused rather than defaulted",
          arguments: ["pt-BR", "fr-FR", "de-DE", "ja-JP", ""])
    func unsupportedLanguageIsNil(identifier: String) {
        // Defaulting to English here would run the English filler list over
        // Portuguese and delete real words.
        #expect(TranscriptLanguage(localeIdentifier: identifier) == nil)
    }

    // ── CLEAN ───────────────────────────────────────────────────────────────

    @Test("Spanish hesitations are removed")
    func spanishFillers() {
        for token in ["eh", "em", "mmm", "ah", "Eh", "EHH"] {
            #expect(DisfluencyLexicon.isFiller(token, in: .spanish),
                    "\(token) should be a filler")
        }
    }

    @Test("Spanish affirmations are never removed")
    func spanishAffirmationsProtected() {
        // Deleting one can invert the sense of an answer, which is the failure
        // CLEAN must not have.
        for token in ["ajá", "aja", "mjm", "ujum"] {
            #expect(!DisfluencyLexicon.isFiller(token, in: .spanish),
                    "\(token) affirms and must survive")
        }
    }

    @Test("“este” is a filler alone and a determiner before a noun")
    func contextualFiller() {
        // The hard case, and the reason the Spanish list is not a translation
        // of the English one.
        #expect(DisfluencyLexicon.isFiller("este", in: .spanish, following: nil))
        #expect(DisfluencyLexicon.isFiller("este", in: .spanish, following: "eh"))
        #expect(!DisfluencyLexicon.isFiller("este", in: .spanish, following: "informe"))
        #expect(!DisfluencyLexicon.isFiller("esto", in: .spanish, following: "es"))
    }

    @Test("English rules do not leak into Spanish and vice versa")
    func lexiconsAreSeparate() {
        // "um" is not a Spanish hesitation; "este" is not an English one.
        #expect(!DisfluencyLexicon.isFiller("um", in: .spanish))
        #expect(!DisfluencyLexicon.isFiller("este", in: .english, following: nil))
    }

    @Test("Emphatic Spanish repetition is not collapsed")
    func spanishDoubling() {
        // "no no" is an emphatic refusal. Collapsing it weakens a negation,
        // and in Spanish the lexical defences are all that stand behind one.
        for token in ["no", "muy", "sí", "que", "casi"] {
            #expect(!DisfluencyLexicon.mayCollapseRepetition(of: token, in: .spanish),
                    "\(token) \(token) is legitimate Spanish")
        }
        // A genuine stumble still collapses.
        #expect(DisfluencyLexicon.mayCollapseRepetition(of: "presupuesto", in: .spanish))
    }

    // ── POLISH validation ───────────────────────────────────────────────────

    @Test("Semantic distance catches English negation and misses Spanish",
          .enabled(if: SemanticSimilarity.shared.isAvailable(for: .english)
                       && SemanticSimilarity.shared.isAvailable(for: .spanish)))
    func negationDetectionDiffersByLanguage() {
        // This test exists to stop someone "fixing" Spanish polish by retuning
        // the threshold. The two populations are inverted, not merely shifted:
        // Spanish negations score closer than Spanish paraphrases, so no
        // threshold separates them.
        let english = [("We approved the budget.", "We did not approve the budget."),
                       ("The server is running.", "The server is not running."),
                       ("She agreed to the terms.", "She never agreed to the terms."),
                       ("I can finish by Friday.", "I cannot finish by Friday."),
                       ("There was a problem.", "There was no problem.")]
        let spanish = [("Aprobamos el presupuesto.", "No aprobamos el presupuesto."),
                       ("El servidor está funcionando.", "El servidor no está funcionando."),
                       ("Ella aceptó los términos.", "Ella nunca aceptó los términos."),
                       ("Puedo terminar el viernes.", "No puedo terminar el viernes."),
                       ("Hubo un problema.", "No hubo ningún problema.")]

        let threshold = ValidationThresholds.default.maximumSemanticDistance
        let similarity = SemanticSimilarity.shared

        let englishCaught = english.count {
            (similarity.distance($0.0, $0.1, in: .english) ?? 0) > threshold
        }
        let spanishCaught = spanish.count {
            (similarity.distance($0.0, $0.1, in: .spanish) ?? 0) > threshold
        }

        #expect(englishCaught == english.count,
                "English distance should catch every negation; caught \(englishCaught)")
        // If this ever catches one, re-measure and revisit catchesNegation(in:).
        #expect(spanishCaught == 0,
                "Spanish distance should catch no negation; caught \(spanishCaught)")

        // And the documented consequence stays in step with the measurement.
        #expect(SemanticSimilarity.catchesNegation(in: .english))
        #expect(!SemanticSimilarity.catchesNegation(in: .spanish))
    }

    @Test("Spanish paraphrase still reads as close",
          .enabled(if: SemanticSimilarity.shared.isAvailable(for: .spanish)))
    func spanishParaphraseAccepted() {
        let distance = SemanticSimilarity.shared.distance(
            "Aprobamos el presupuesto el lunes.",
            "El presupuesto fue aprobado el lunes.",
            in: .spanish)
        let threshold = ValidationThresholds.default.maximumSemanticDistance
        #expect((distance ?? 1) < threshold)
    }

    @Test("Unrelated Spanish text is still rejected",
          .enabled(if: SemanticSimilarity.shared.isAvailable(for: .spanish)))
    func spanishHallucinationRejected() {
        // The check is blind to negation but not useless: it still guards
        // against wholesale invention.
        let distance = SemanticSimilarity.shared.distance(
            "Aprobamos el presupuesto el lunes.",
            "El gato se sentó en la alfombra.",
            in: .spanish)
        let threshold = ValidationThresholds.default.maximumSemanticDistance
        #expect((distance ?? 0) > threshold)
    }
}

@Suite("Spanish semantic lexicons")
struct SpanishLexiconTests {

    @Test("Spanish negation is recognised, accented or not")
    func negations() {
        let lexicon = SemanticLexicons.negations(for: .spanish)
        for word in ["no", "nunca", "jamás", "jamas", "nada", "nadie",
                     "ningún", "ningun", "tampoco", "sin", "ni"] {
            #expect(lexicon.contains(word), "\(word) negates")
        }
    }

    @Test("Double negation is counted, not reasoned about")
    func doubleNegation() {
        // "no vimos nada" is one negation in meaning and two tokens. The check
        // compares totals on each side, so a rewrite that drops either token
        // changes the count and gets caught — which is the behaviour we want
        // without teaching it Spanish grammar.
        let lexicon = SemanticLexicons.negations(for: .spanish)
        let original = SemanticLexicons.count(
            TextTokenizer.tokens("No vimos nada en el informe."), in: lexicon)
        let flipped = SemanticLexicons.count(
            TextTokenizer.tokens("Vimos algo en el informe."), in: lexicon)
        #expect(original == 2)
        #expect(flipped == 0)
        #expect(original != flipped, "a dropped negation must change the count")
    }

    @Test("Negations are not also stop words")
    func negationsAreNotDiscounted() {
        // A negation discounted as a function word would vanish from content
        // overlap, which is how "no" gets lost.
        let stops = SemanticLexicons.stopWords(for: .spanish)
        for word in SemanticLexicons.negations(for: .spanish) {
            #expect(!stops.contains(word), "\(word) negates and must not be a stop word")
        }
    }

    @Test("Spanish hedges are recognised")
    func hedges() {
        let lexicon = SemanticLexicons.hedges(for: .spanish)
        for word in ["quizá", "quizas", "probablemente", "podría", "parece", "creo"] {
            #expect(lexicon.contains(word), "\(word) hedges")
        }
    }

    @Test("English and Spanish lexicons stay separate")
    func noLeakage() {
        #expect(!SemanticLexicons.negations(for: .english).contains("nunca"))
        #expect(!SemanticLexicons.negations(for: .spanish).contains("never"))
        #expect(!SemanticLexicons.stopWords(for: .english).contains("el"))
    }

    @Test("The gauntlet catches a Spanish meaning inversion without the embedding")
    func gauntletCatchesSpanishInversion() throws {
        // The whole point of the Spanish negation list. The semantic check is
        // blind here, so this must be caught lexically or not at all.
        let report = try ValidationGauntlet().validate(
            original: ["Aprobamos el presupuesto el lunes."],
            revised: ["No aprobamos el presupuesto el lunes."],
            language: .spanish)
        #expect(!report.passed, "a flipped Spanish sentence must be rejected")
        #expect(report.failureReasons.contains { $0.localizedCaseInsensitiveContains("negation") },
                "rejection should name the polarity check: \(report.failureReasons)")
    }

    @Test("A faithful Spanish rewrite still passes")
    func gauntletAcceptsSpanishParaphrase() throws {
        let report = try ValidationGauntlet().validate(
            original: ["aprobamos el presupuesto el lunes"],
            revised: ["Aprobamos el presupuesto el lunes."],
            language: .spanish)
        #expect(report.passed, "capitalisation is what POLISH fixes: \(report.failureReasons)")
    }
}
