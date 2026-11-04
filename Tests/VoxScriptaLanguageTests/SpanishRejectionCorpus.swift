import Testing
import Foundation
import VoxScriptaCore
@testable import VoxScriptaLanguage

/// The evidence behind enabling POLISH in Spanish.
///
/// In English the gauntlet has two independent defences against a reversed
/// meaning: the lexical polarity count and the semantic-distance check. In
/// Spanish the second one is blind — measured over five negation pairs it
/// caught none — so enabling the stage rests entirely on whether the lexical
/// checks hold on their own.
///
/// That is a claim about measurement, not about design, so it is measured here.
/// Each case is a rewrite a model could plausibly produce, labelled with
/// whether the gauntlet must refuse it. Corruptions are drawn from the failure
/// modes §14 names: changed quantities, substituted names, dropped negations,
/// flattened hedges, invented detail, and wholesale replacement. The accepted
/// cases matter just as much — a gauntlet that rejects everything is not safe,
/// it is useless.
enum SpanishRejectionCorpus {

    struct Case: Sendable {
        let original: String
        let revised: String
        /// What the gauntlet is expected to do, and why.
        let mustReject: Bool
        let note: String
    }

    /// Rewrites that change meaning. Every one must be refused.
    static let corruptions: [Case] = [
        // ── Polarity: the class the semantic check cannot see ───────────────
        .init(original: "No aprobamos el presupuesto el lunes.",
              revised: "Aprobamos el presupuesto el lunes.",
              mustReject: true, note: "negation deleted"),
        .init(original: "El servidor no está funcionando.",
              revised: "El servidor está funcionando.",
              mustReject: true, note: "negation deleted"),
        .init(original: "Ella nunca aceptó los términos.",
              revised: "Ella aceptó los términos.",
              mustReject: true, note: "nunca deleted"),
        .init(original: "Puedo terminar el viernes.",
              revised: "No puedo terminar el viernes.",
              mustReject: true, note: "negation added"),
        .init(original: "No vimos nada en el informe.",
              revised: "Vimos algo en el informe.",
              mustReject: true, note: "double negation collapsed and inverted"),
        .init(original: "Tampoco funcionó la segunda prueba.",
              revised: "Funcionó la segunda prueba.",
              mustReject: true, note: "tampoco deleted"),
        .init(original: "No hay ningún problema con la entrega.",
              revised: "Hay un problema con la entrega.",
              mustReject: true, note: "both negations deleted"),

        // ── Quantities ──────────────────────────────────────────────────────
        .init(original: "Vendimos quinientas unidades el mes pasado.",
              revised: "Vendimos 900 unidades el mes pasado.",
              mustReject: true, note: "quantity changed"),
        .init(original: "El informe tiene treinta y dos páginas.",
              revised: "El informe tiene unas treinta páginas.",
              mustReject: true, note: "quantity rounded"),
        .init(original: "La reunión empieza a las nueve y media.",
              revised: "La reunión empieza a las diez.",
              mustReject: true, note: "time changed"),

        // ── Names ───────────────────────────────────────────────────────────
        .init(original: "María revisó el contrato con Hernández.",
              revised: "María revisó el contrato con Fernández.",
              mustReject: true, note: "surname altered"),
        .init(original: "Lo comentamos en la oficina de Madrid.",
              revised: "Lo comentamos en la oficina de Barcelona.",
              mustReject: true, note: "place substituted"),

        // ── Modality: a qualified claim promoted to a flat one ──────────────
        .init(original: "Quizá terminemos antes del viernes.",
              revised: "Terminaremos antes del viernes.",
              mustReject: true, note: "hedge removed"),
        .init(original: "Creo que el coste sube un poco.",
              revised: "El coste sube.",
              mustReject: true, note: "hedge removed and detail lost"),
        .init(original: "Probablemente haya que repetir la prueba.",
              revised: "Hay que repetir la prueba.",
              mustReject: true, note: "hedge removed"),

        // ── Invention and wholesale replacement ─────────────────────────────
        .init(original: "Revisamos el informe.",
              revised: "Revisamos el informe trimestral de ventas con el equipo "
                     + "de finanzas el martes por la mañana.",
              mustReject: true, note: "detail invented"),
        .init(original: "Aprobamos el presupuesto el lunes.",
              revised: "El gato se sentó en la alfombra.",
              mustReject: true, note: "unrelated text"),
        .init(original: "El equipo entregó el proyecto a tiempo y sin incidencias.",
              revised: "Bien.",
              mustReject: true, note: "meaning discarded"),

        // ── Orthography, found by running real audio ────────────────────────
        // Not hypothetical. The model returned both of these for the test
        // recording, and every other check passed them: same lemma, same
        // content words, negligible distance, simply misspelled.
        .init(original: "Buenos días a todos.",
              revised: "Buenos dias a todos.",
              mustReject: true, note: "accent stripped"),
        .init(original: "Tengo que repetir el análisis.",
              revised: "Tengo que repetir el analisis.",
              mustReject: true, note: "accent stripped"),
    ]

    /// Rewrites a polish pass should be allowed to make. Rejecting these
    /// would make the stage useless rather than safe.
    static let legitimate: [Case] = [
        .init(original: "aprobamos el presupuesto el lunes",
              revised: "Aprobamos el presupuesto el lunes.",
              mustReject: false, note: "capitalisation and full stop"),
        .init(original: "el servidor no esta funcionando",
              revised: "El servidor no está funcionando.",
              mustReject: false, note: "accent restored"),
        .init(original: "Quizá terminemos antes del viernes",
              revised: "Quizá terminemos antes del viernes.",
              mustReject: false, note: "punctuation only"),
        .init(original: "no vimos nada en el informe",
              revised: "No vimos nada en el informe.",
              mustReject: false, note: "double negation preserved"),
        .init(original: "vendimos quinientas unidades el mes pasado",
              revised: "Vendimos quinientas unidades el mes pasado.",
              mustReject: false, note: "quantity preserved as words"),
        .init(original: "María revisó el contrato con Hernández",
              revised: "María revisó el contrato con Hernández.",
              mustReject: false, note: "names preserved"),
        .init(original: "creo que el coste sube un poco",
              revised: "Creo que el coste sube un poco.",
              mustReject: false, note: "hedge preserved"),
        .init(original: "el informe tiene treinta y dos páginas",
              revised: "El informe tiene treinta y dos páginas.",
              mustReject: false, note: "compound number preserved"),
        .init(original: "tampoco funcionó la segunda prueba",
              revised: "Tampoco funcionó la segunda prueba.",
              mustReject: false, note: "tampoco preserved"),
        .init(original: "no hay ningún problema con la entrega",
              revised: "No hay ningún problema con la entrega.",
              mustReject: false, note: "both negations preserved"),
        .init(original: "buenos dias a todos",
              revised: "Buenos días a todos.",
              mustReject: false, note: "accent added, which is a repair"),
    ]

    static var all: [Case] { corruptions + legitimate }
}

@Suite("Spanish rejection corpus")
struct SpanishRejectionCorpusTests {

    private func rejects(_ item: SpanishRejectionCorpus.Case) throws -> Bool {
        let report = try ValidationGauntlet().validate(
            original: [item.original], revised: [item.revised], language: .spanish)
        return !report.passed
    }

    @Test("Every meaning-changing rewrite is refused")
    func corruptionsAreCaught() throws {
        var escaped: [String] = []
        for item in SpanishRejectionCorpus.corruptions where try !rejects(item) {
            escaped.append("\(item.note): “\(item.revised)”")
        }
        #expect(escaped.isEmpty, "corruptions the gauntlet let through: \(escaped)")
    }

    @Test("Legitimate rewrites are not refused")
    func legitimateRewritesPass() throws {
        var blocked: [String] = []
        for item in SpanishRejectionCorpus.legitimate where try rejects(item) {
            let report = try ValidationGauntlet().validate(
                original: [item.original], revised: [item.revised], language: .spanish)
            blocked.append("\(item.note): \(report.failureReasons)")
        }
        #expect(blocked.isEmpty, "legitimate rewrites the gauntlet blocked: \(blocked)")
    }

    @Test("A verb mood change is not yet caught — a known gap")
    func moodChangeEscapes() throws {
        // Found in the same run. "Quizá terminemos" is subjunctive and
        // "Quizá terminaremos" is future indicative: the hedge survives, so
        // modality passes; the lemma is shared, so the content check passes.
        // Detecting it needs morphology the gauntlet does not have.
        //
        // The shift is small — both remain hedged by "quizá" — so the stage
        // stays enabled, but this is recorded rather than left unsaid. If this
        // test starts failing, the gap has been closed and it should become a
        // corruption case.
        let report = try ValidationGauntlet().validate(
            original: ["Quizá terminemos antes del viernes."],
            revised: ["Quizá terminaremos antes del viernes."],
            language: .spanish)
        #expect(report.passed, "mood change is now caught — move this to the corruptions")
    }

    @Test("Negation is caught lexically, with the embedding contributing nothing")
    func negationCaughtWithoutEmbedding() throws {
        // The claim the whole gate rests on. Each of these is a polarity
        // change, and the semantic-distance check is known blind to all of
        // them in Spanish, so a pass here is the lexical check working alone.
        let polarity = SpanishRejectionCorpus.corruptions.filter {
            $0.note.contains("negation") || $0.note.contains("nunca")
                || $0.note.contains("tampoco") || $0.note.contains("negations")
        }
        #expect(polarity.count >= 6, "the corpus should carry real polarity coverage")

        for item in polarity {
            let report = try ValidationGauntlet().validate(
                original: [item.original], revised: [item.revised], language: .spanish)
            #expect(!report.passed, "escaped: \(item.note)")
            #expect(report.failureReasons.contains { $0.localizedCaseInsensitiveContains("negation") },
                    "\(item.note) was caught, but not by the polarity check: \(report.failureReasons)")
        }
    }
}

@Suite("Polish readiness")
struct PolishReadinessTests {

    @Test("Both languages are admitted, by different evidence")
    func bothValidated() {
        #expect(PolishReadiness.isValidated(.english))
        #expect(PolishReadiness.isValidated(.spanish))
        // And they qualify differently: English has the embedding behind the
        // lexical check, Spanish does not.
        #expect(SemanticSimilarity.catchesNegation(in: .english))
        #expect(!SemanticSimilarity.catchesNegation(in: .spanish))
    }

    @Test("A language with no polarity lexicon cannot be admitted")
    func structuralGuard() {
        // The guard that covers failures the corpus did not think of: without
        // a negation list there is nothing to catch an inversion, whatever the
        // readiness table claims.
        for language in TranscriptLanguage.allCases {
            if PolishReadiness.isValidated(language) {
                #expect(!SemanticLexicons.negations(for: language).isEmpty,
                        "\(language) is admitted but has no negation lexicon")
            }
        }
    }

    @Test("Withholding reports a reason, running reports none")
    func reasons() {
        #expect(PolishReadiness.withheldReason(for: nil) == "noLexicons")
        #expect(PolishReadiness.withheldReason(for: .spanish) == nil)
        #expect(PolishReadiness.withheldReason(for: .english) == nil)
    }
}
